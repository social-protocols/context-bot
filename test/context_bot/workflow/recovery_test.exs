defmodule ContextBot.Workflow.RecoveryTest do
  use ContextBot.DataCase, async: false

  import Ecto.Query

  alias ContextBot.Research.{BudgetEntry, ResponseEnvelope}
  alias ContextBot.Settings
  alias ContextBot.Workflow.{Invocation, Recovery}

  @now ~U[2026-08-10 18:00:00.000000Z]

  test "startup recovery returns orphaned thread work to the correct dry and public queues" do
    dry = invocation(:capturing_thread, true, "startup-dry")
    public = invocation(:capturing_thread, false, "startup-public")
    dry_job = executing_job(dry, "ContextBot.Workers.ThreadWorker", :dry_thread)
    public_job = executing_job(public, "ContextBot.Workers.ThreadWorker", :thread)

    assert {:ok, %{resumed: 2}} = recover(startup?: true)

    assert Repo.reload!(dry_job).state == "available"
    assert Repo.reload!(dry_job).queue == "dry_thread"
    assert Repo.reload!(public_job).state == "available"
    assert Repo.reload!(public_job).queue == "thread"
  end

  test "research without exposure or with a reservation resumes without duplicating budget" do
    no_entry = invocation(:researching, true, "no-entry")
    no_entry_job = executing_job(no_entry, "ContextBot.Workers.ResearchWorker", :dry_research)

    reserved = invocation(:researching, false, "reserved")
    reserved_job = executing_job(reserved, "ContextBot.Workers.ResearchWorker", :research)
    _entry = budget_entry(reserved, :reserved, nil)

    assert :resumed = recover_invocation(no_entry, startup?: true)
    assert :resumed = recover_invocation(reserved, startup?: true)

    for {invocation, job, queue} <- [
          {no_entry, no_entry_job, "dry_research"},
          {reserved, reserved_job, "research"}
        ] do
      persisted = Repo.reload!(invocation)
      assert persisted.stage == :thread_ready
      assert persisted.research_claim_token == nil
      assert Repo.reload!(job).state == "available"
      assert Repo.reload!(job).queue == queue
    end

    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "sent research without a stored envelope waits out the HTTP timeout" do
    invocation = invocation(:researching, true, "ambiguous")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)
    entry = budget_entry(invocation, :sent, nil)

    assert :resumed = recover_invocation(invocation, startup?: true)
    assert :unchanged = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :researching
    assert persisted.failure_category == nil
    assert persisted.research_claim_token == nil
    assert Repo.reload!(entry).state == :sent
    assert Repo.reload!(job).state == "scheduled"
    assert DateTime.diff(Repo.reload!(job).scheduled_at, @now, :millisecond) == 300_000
    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "sent research without an envelope starts a new attempt after the HTTP timeout" do
    invocation = invocation(:researching, true, "ambiguous-elapsed")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)
    entry = budget_entry(invocation, :sent, nil)
    later = DateTime.add(@now, 300_001, :millisecond)

    assert :resumed = recover_invocation(invocation, startup?: true, now: later)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :thread_ready
    assert persisted.failure_category == nil
    assert persisted.completed_at == nil
    assert Repo.reload!(entry).state == :indeterminate
    assert Repo.reload!(job).state == "available"
    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "an older unrecorded attempt inside the timeout parks instead of sending a reservation" do
    invocation = invocation(:researching, false, "older-ambiguous")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)
    ambiguous = budget_entry(invocation, :sent, nil)

    reserved =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: "recovery-#{invocation.id}-retry-reserved",
        invocation_id: invocation.id,
        budget_date: DateTime.to_date(@now),
        kind: :retry,
        reserved_microdollars: 5_000_000,
        state: :reserved,
        research_claim_token: "old-research-owner"
      })
      |> Repo.insert!()

    assert :resumed = recover_invocation(invocation, startup?: true)
    assert Repo.reload!(invocation).stage == :researching
    assert Repo.reload!(ambiguous).state == :sent
    assert Repo.reload!(reserved).state == :reserved
    assert Repo.reload!(job).state == "scheduled"
  end

  test "an older unrecorded attempt past the timeout stays indeterminate and resumes the reservation" do
    invocation = invocation(:researching, false, "older-elapsed")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)
    ambiguous = budget_entry(invocation, :sent, nil)

    reserved =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: "recovery-#{invocation.id}-retry-reserved-elapsed",
        invocation_id: invocation.id,
        budget_date: DateTime.to_date(@now),
        kind: :retry,
        reserved_microdollars: 5_000_000,
        state: :reserved,
        research_claim_token: "old-research-owner"
      })
      |> Repo.insert!()

    later = DateTime.add(@now, 300_001, :millisecond)
    assert :resumed = recover_invocation(invocation, startup?: true, now: later)
    assert Repo.reload!(invocation).stage == :thread_ready
    assert Repo.reload!(ambiguous).state == :indeterminate
    assert Repo.reload!(reserved).state == :reserved
    assert Repo.reload!(job).state == "available"
    assert Repo.aggregate(BudgetEntry, :count) == 2
  end

  test "a stored provider envelope resumes processing without a new reservation" do
    invocation = invocation(:researching, false, "recorded")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)
    entry = budget_entry(invocation, :sent, @now)
    _envelope = response_envelope(invocation, entry)

    assert :resumed = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :thread_ready
    assert Repo.reload!(job).state == "available"
    assert Repo.aggregate(BudgetEntry, :count) == 1
    assert Repo.aggregate(ResponseEnvelope, :count) == 1
  end

  test "a failed structure-parse envelope stays failed without automatic replay" do
    invocation =
      invocation(:failed, true, "structure-parse-failure",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "invalid_structured_output"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)

    job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, @now, :structure)
    _envelope = response_envelope(invocation, entry)

    assert :unchanged = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_detail == %{"reason" => "invalid_structured_output"}
    assert Repo.reload!(job).state == "discarded"
    assert available_research_jobs(invocation) == []
  end

  test "a failed local parser envelope stays failed without automatic replay" do
    invocation =
      invocation(:failed, true, "parser-failure",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "unexpected_tool_use"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)

    job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, @now)
    _envelope = response_envelope(invocation, entry)

    assert :unchanged = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_category == :provider_response
    assert persisted.failure_detail == %{"reason" => "unexpected_tool_use"}
    assert persisted.completed_at == @now
    assert Repo.reload!(entry).state == :sent
    assert Repo.aggregate(BudgetEntry, :count) == 1
    assert Repo.aggregate(ResponseEnvelope, :count) == 1
    assert available_research_jobs(invocation) == []
    assert Repo.reload!(job).state == "discarded"
  end

  test "a failed invalid_structured_output envelope stays failed without automatic replay" do
    invocation =
      invocation(:failed, false, "invalid-structured-output",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "invalid_structured_output"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    _job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, @now)
    _envelope = response_envelope(invocation, entry)

    assert :unchanged = recover_invocation(invocation, startup?: true)
    assert {:ok, %{resumed: 0, unchanged: 1}} = recover(startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_category == :provider_response
    assert persisted.failure_detail == %{"reason" => "invalid_structured_output"}
    assert persisted.completed_at == @now
    assert available_research_jobs(invocation) == []
    assert Repo.aggregate(BudgetEntry, :count) == 1
    assert Repo.aggregate(ResponseEnvelope, :count) == 1
  end

  test "a failed code_execution envelope stays failed without automatic replay" do
    invocation =
      invocation(:failed, false, "code-exec-failure",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "code_execution_failed"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    _job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, @now)
    _envelope = response_envelope(invocation, entry)

    assert :unchanged = recover_invocation(invocation, startup?: true)
    assert {:ok, %{resumed: 0, unchanged: 1}} = recover(startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_detail == %{"reason" => "code_execution_failed"}
    assert available_research_jobs(invocation) == []
    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "a failed document-create envelope is still reopened for local replay" do
    invocation =
      invocation(:failed, false, "document-create-failure",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "standard_site_document_failed"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, @now)
    _envelope = response_envelope(invocation, entry)

    assert :resumed = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :thread_ready
    assert persisted.failure_category == nil
    assert persisted.completed_at == nil
    assert Repo.reload!(entry).state == :sent
    assert [replay] = available_research_jobs(invocation)
    assert replay.id != job.id
    assert replay.state == "available"
  end

  test "failed interrupted_after_send waits while the HTTP timeout is still open" do
    invocation =
      invocation(:failed, false, "failed-interrupt-wait",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "interrupted_after_send"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, nil)

    assert :resumed = recover_invocation(invocation, startup?: true)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :researching
    assert persisted.failure_category == nil
    assert persisted.completed_at == nil
    assert Repo.reload!(entry).state == :sent
    assert [parked] = available_research_jobs(invocation)
    assert parked.id != job.id
    assert parked.state == "scheduled"
    assert DateTime.diff(parked.scheduled_at, @now, :millisecond) == 300_000
  end

  test "failed interrupted_after_send is reopened after the HTTP timeout" do
    invocation =
      invocation(:failed, false, "failed-interrupt",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "interrupted_after_send"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        completed_at: @now
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    job =
      job |> Ecto.Changeset.change(%{state: "discarded", discarded_at: @now}) |> Repo.update!()

    entry = budget_entry(invocation, :sent, nil)
    later = DateTime.add(@now, 300_001, :millisecond)

    assert {:ok, %{resumed: 1}} = recover(startup?: true, now: later)
    assert {:ok, %{resumed: 0, unchanged: 1}} = recover(startup?: true, now: later)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :thread_ready
    assert persisted.failure_category == nil
    assert persisted.failure_detail == nil
    assert persisted.completed_at == nil
    assert Repo.reload!(entry).state == :indeterminate
    assert [replay] = available_research_jobs(invocation)
    assert replay.id != job.id
    assert replay.state == "available"
    assert replay.queue == "research"
  end

  test "a published reply is never given a second post" do
    invocation =
      invocation(:failed, false, "already-published",
        failure_category: :provider_response,
        failure_detail: %{"reason" => "interrupted_after_send"},
        canonical_thread: "thread",
        canonical_thread_version: "1",
        anthropic_messages: %{"model" => "claude-sonnet-5", "messages" => []},
        reply_uri: "at://did:plc:bot/app.bsky.feed.post/already",
        reply_cid: "bafy-already",
        completed_at: @now
      )

    later = DateTime.add(@now, 300_001, :millisecond)
    assert :unchanged = recover_invocation(invocation, startup?: true, now: later)
    assert Repo.reload!(invocation).stage == :failed
    assert Repo.reload!(invocation).reply_uri == "at://did:plc:bot/app.bsky.feed.post/already"

    refute Repo.exists?(
             from job in Oban.Job,
               where: job.worker == "ContextBot.Workers.ReplyWorker"
           )
  end

  test "a response timestamp without its durable envelope waits while the timeout is open" do
    invocation = invocation(:researching, false, "missing-envelope")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)
    entry = budget_entry(invocation, :sent, @now)

    assert :resumed = recover_invocation(invocation, startup?: true)
    assert Repo.reload!(invocation).stage == :researching
    assert Repo.reload!(entry).state == :sent
    assert Repo.reload!(job).state == "scheduled"
  end

  test "publication is safely resumed only for public invocations" do
    public = invocation(:publishing, false, "publication")
    job = executing_job(public, "ContextBot.Workers.ReplyWorker", :reply)

    assert :resumed = recover_invocation(public, startup?: true)
    persisted = Repo.reload!(public)
    assert persisted.stage == :reply_ready
    assert persisted.publication_claim_token == nil
    assert Repo.reload!(job).state == "available"

    dry = invocation(:publishing, true, "impossible-dry-publication")
    dry_job = executing_job(dry, "ContextBot.Workers.ReplyWorker", :reply)
    assert :terminalized = recover_invocation(dry, startup?: true)
    assert Repo.reload!(dry).stage == :failed
    assert Repo.reload!(dry_job).state == "discarded"
  end

  test "runtime recovery respects fresh leases and recovers them after expiry" do
    fresh = invocation(:researching, false, "fresh", research_claimed_at: @now)
    job = executing_job(fresh, "ContextBot.Workers.ResearchWorker", :research)

    assert :unchanged =
             recover_invocation(fresh,
               startup?: false,
               now: DateTime.add(@now, 21_599_999, :millisecond)
             )

    assert Repo.reload!(job).state == "executing"

    assert :resumed =
             recover_invocation(fresh,
               startup?: false,
               now: DateTime.add(@now, 21_600_001, :millisecond)
             )

    assert Repo.reload!(job).state == "available"
  end

  test "runtime identity and thread leases use their exact HTTP timeout boundaries" do
    configured =
      Settings.load(
        bot_enabled: false,
        atproto_http_timeout_ms: 2_000,
        atproto_session_timeout_ms: 3_000,
        thread_fetch_timeout_ms: 4_000
      )

    identity = invocation(:checking_eligibility, false, "identity-boundary")
    identity_job = executing_job(identity, "ContextBot.Workers.EligibilityWorker", :eligibility)
    set_attempted_at(identity_job, @now)

    thread = invocation(:capturing_thread, true, "thread-boundary")
    thread_job = executing_job(thread, "ContextBot.Workers.ThreadWorker", :dry_thread)
    set_attempted_at(thread_job, @now)

    assert :unchanged =
             Recovery.recover_invocation(identity,
               startup?: false,
               now: DateTime.add(@now, 32_999, :millisecond),
               settings: configured
             )

    assert :resumed =
             Recovery.recover_invocation(identity,
               startup?: false,
               now: DateTime.add(@now, 33_001, :millisecond),
               settings: configured
             )

    assert :unchanged =
             Recovery.recover_invocation(thread,
               startup?: false,
               now: DateTime.add(@now, 33_999, :millisecond),
               settings: configured
             )

    assert :resumed =
             Recovery.recover_invocation(thread,
               startup?: false,
               now: DateTime.add(@now, 34_001, :millisecond),
               settings: configured
             )

    assert Repo.reload!(identity_job).queue == "eligibility"
    assert Repo.reload!(thread_job).queue == "dry_thread"
  end

  test "deferred and terminal invocations remain unchanged" do
    deferred = invocation(:deferred_budget, false, "deferred")
    complete = invocation(:complete, true, "complete")

    assert :unchanged = recover_invocation(deferred, startup?: false)
    assert :unchanged = recover_invocation(complete, startup?: true)
    assert Repo.reload!(deferred).stage == :deferred_budget
    assert Repo.reload!(complete).stage == :complete
  end

  test "permanent non-replayable failures stay failed" do
    invocation =
      invocation(:failed, false, "identity-unavailable",
        failure_category: :identity_unavailable,
        completed_at: @now
      )

    assert :unchanged = recover_invocation(invocation, startup?: true)
    assert Repo.reload!(invocation).stage == :failed
    assert Repo.reload!(invocation).failure_category == :identity_unavailable
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "repeated recovery does not create duplicate work" do
    invocation = invocation(:researching, true, "idempotent")
    _job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)

    assert {:ok, first} = recover(startup?: true)
    assert {:ok, second} = recover(startup?: true)
    assert first.resumed == 1
    assert second.resumed == 0

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == "ContextBot.Workers.ResearchWorker" and
                   job.queue == "dry_research" and job.state == "available"
             ),
             :count
           ) == 1
  end

  test "dry startup recovery filters before the cap and drains every bounded page" do
    public =
      for index <- 1..105 do
        invocation(:capturing_thread, false, "public-backlog-#{index}")
      end

    public_jobs =
      Enum.map(public, &executing_job(&1, "ContextBot.Workers.ThreadWorker", :thread))

    dry =
      for index <- 1..105 do
        invocation(:capturing_thread, true, "dry-backlog-#{index}")
      end

    dry_jobs =
      Enum.map(dry, &executing_job(&1, "ContextBot.Workers.ThreadWorker", :dry_thread))

    assert {:ok, %{examined: 105, resumed: 105, terminalized: 0, unchanged: 0}} =
             recover(startup?: true, workflow: :dry_run, batch_size: 100)

    assert Enum.all?(public_jobs, &(Repo.reload!(&1).state == "executing"))
    assert Enum.all?(dry_jobs, &(Repo.reload!(&1).state == "available"))
  end

  defp recover(options) do
    Recovery.recover_orphans(
      Keyword.merge([now: @now, settings: Settings.load(bot_enabled: false)], options)
    )
  end

  defp recover_invocation(invocation, options) do
    Recovery.recover_invocation(
      invocation,
      Keyword.merge([now: @now, settings: Settings.load(bot_enabled: false)], options)
    )
  end

  # Fixture construction intentionally covers the full recovery stage matrix.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp invocation(stage, dry_run, suffix, extra \\ []) do
    uri = "local://recovery/#{suffix}"
    cid = "local:#{suffix}"

    attrs = %{
      dry_run: dry_run,
      target_uri: if(dry_run, do: "at://did:plc:target/app.bsky.feed.post/#{suffix}"),
      invocation_text: if(dry_run, do: "Question?"),
      invocation_uri: uri,
      notification_cid: cid,
      current_cid: cid,
      actor_did: if(dry_run, do: "local:operator", else: "did:plc:actor"),
      raw_notification: %{"source" => "test"},
      received_at: @now,
      status: stage,
      stage: stage,
      canonical_thread: if(stage in [:thread_ready, :researching, :failed], do: "thread"),
      canonical_thread_version: if(stage in [:thread_ready, :researching, :failed], do: "1"),
      research_claim_token: if(stage == :researching, do: "old-research-owner"),
      research_claimed_at: if(stage == :researching, do: @now),
      publication_claim_token: if(stage == :publishing, do: "old-publication-owner"),
      publication_claimed_at: if(stage == :publishing, do: @now)
    }

    attrs = Map.merge(attrs, Map.new(extra))

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp executing_job(invocation, worker, queue) do
    job =
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
      |> Oban.Job.new(worker: worker, queue: queue)
      |> Repo.insert!()

    job
    |> Ecto.Changeset.change(%{
      state: "executing",
      attempted_at: DateTime.add(@now, -60, :second),
      attempted_by: ["old-node"]
    })
    |> Repo.update!()
  end

  defp available_research_jobs(invocation) do
    invocation
    |> research_jobs()
    |> Enum.filter(&(&1.state in ["available", "scheduled"]))
  end

  defp research_jobs(invocation) do
    Repo.all(
      from job in Oban.Job,
        where:
          job.worker == "ContextBot.Workers.ResearchWorker" and
            fragment("json_extract(?, '$.uri')", job.args) == ^invocation.invocation_uri and
            fragment("json_extract(?, '$.cid')", job.args) == ^invocation.notification_cid,
        order_by: job.id
    )
  end

  defp set_attempted_at(job, attempted_at) do
    job
    |> Ecto.Changeset.change(attempted_at: attempted_at)
    |> Repo.update!()
  end

  defp budget_entry(invocation, state, response_recorded_at, kind \\ :research) do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "recovery-#{invocation.id}-#{kind}",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: kind,
      reserved_microdollars: 5_000_000,
      state: state,
      sent_at: if(state == :sent, do: @now),
      response_recorded_at: response_recorded_at,
      research_claim_token: "old-research-owner"
    })
    |> Repo.insert!()
  end

  defp response_envelope(invocation, entry) do
    raw_body = ~s({"type":"message"})
    metadata_blob = :erlang.term_to_binary(%{status: 200, attempt_key: entry.attempt_key})

    %ResponseEnvelope{}
    |> ResponseEnvelope.changeset(%{
      invocation_id: invocation.id,
      budget_entry_id: entry.id,
      attempt_key: entry.attempt_key,
      kind: :research,
      status: 200,
      metadata_blob: metadata_blob,
      raw_body: raw_body,
      received_at: @now,
      duration_ms: 10,
      storage_bytes: byte_size(metadata_blob) + byte_size(raw_body)
    })
    |> Repo.insert!()
  end
end
