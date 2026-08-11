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

  test "sent research without a stored envelope terminalizes exactly once" do
    invocation = invocation(:researching, true, "ambiguous")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :dry_research)
    entry = budget_entry(invocation, :sent, nil)

    assert :terminalized = recover_invocation(invocation, startup?: true)
    assert :unchanged = recover_invocation(invocation, startup?: true)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_category == :provider_response
    assert persisted.failure_detail == %{"reason" => "interrupted_after_send"}
    assert persisted.research_claim_token == nil
    assert Repo.reload!(entry).state == :indeterminate
    assert Repo.reload!(job).state == "discarded"
    assert Repo.aggregate(BudgetEntry, :count) == 1

    refute Repo.exists?(
             from candidate in Oban.Job,
               where:
                 candidate.queue in ["research", "dry_research", "reply"] and
                   candidate.state in ["available", "scheduled", "executing"]
           )
  end

  test "an older ambiguous attempt terminalizes despite a newer legacy reservation" do
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

    assert :terminalized = recover_invocation(invocation, startup?: true)
    assert Repo.reload!(invocation).stage == :failed
    assert Repo.reload!(ambiguous).state == :indeterminate
    assert Repo.reload!(reserved).state == :reserved
    assert Repo.reload!(job).state == "discarded"
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

  test "a response timestamp without its durable envelope is treated as ambiguous" do
    invocation = invocation(:researching, false, "missing-envelope")
    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)
    entry = budget_entry(invocation, :sent, @now)

    assert :terminalized = recover_invocation(invocation, startup?: true)
    assert Repo.reload!(invocation).stage == :failed
    assert Repo.reload!(entry).state == :indeterminate
    assert Repo.reload!(job).state == "discarded"
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
      canonical_thread: if(stage in [:thread_ready, :researching], do: "thread"),
      canonical_thread_version: if(stage in [:thread_ready, :researching], do: "1"),
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

  defp set_attempted_at(job, attempted_at) do
    job
    |> Ecto.Changeset.change(attempted_at: attempted_at)
    |> Repo.update!()
  end

  defp budget_entry(invocation, state, response_recorded_at) do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "recovery-#{invocation.id}-research",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: :research,
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
