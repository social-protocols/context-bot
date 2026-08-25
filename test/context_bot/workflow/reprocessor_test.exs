defmodule ContextBot.Workflow.ReprocessorTest do
  use ContextBot.DataCase, async: false

  import Ecto.Query

  alias ContextBot.Research.{BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workflow.{Invocation, Reprocessor}

  @now ~U[2026-08-11 22:00:00.000000Z]

  test "reopens a dry failure from its complete retained response in one durable handoff" do
    invocation = reprocessable_invocation(true, "dry-success")
    entry = recorded_attempt(invocation)
    envelope = recorded_envelope(invocation, entry)

    assert {:ok, reopened} = Reprocessor.reprocess(invocation.id, now: @now)

    assert reopened.status == :thread_ready
    assert reopened.stage == :thread_ready
    assert reopened.failure_category == nil
    assert reopened.failure_detail == nil
    assert reopened.completed_at == nil
    assert reopened.research_claim_token == nil
    assert reopened.research_claimed_at == nil
    assert reopened.publication_claim_token == nil
    assert reopened.publication_claimed_at == nil
    assert reopened.defer_until == nil
    assert reopened.deferred_attempt_kind == nil
    assert reopened.recovery_checked_at == @now
    assert reopened.anthropic_messages == invocation.anthropic_messages
    assert reopened.anthropic_usage == invocation.anthropic_usage
    assert reopened.canonical_media == invocation.canonical_media

    assert Repo.get!(BudgetEntry, entry.id).state == :settled
    assert Repo.get!(ResponseEnvelope, envelope.id).raw_body == envelope.raw_body
    assert [job] = research_jobs(invocation)
    assert job.state == "available"
    assert job.queue == "dry_research"
  end

  test "uses the public research queue for a public invocation" do
    invocation = reprocessable_invocation(false, "public-success")
    entry = recorded_attempt(invocation)
    _envelope = recorded_envelope(invocation, entry)

    assert {:ok, _reopened} = Reprocessor.reprocess(invocation.id, now: @now)
    assert [job] = research_jobs(invocation)
    assert job.queue == "research"
  end

  test "reopens a response-recorded indeterminate attempt for local resettlement" do
    invocation = reprocessable_invocation(true, "recorded-indeterminate")

    entry =
      invocation
      |> recorded_attempt()
      |> Ecto.Changeset.change(%{state: :indeterminate, settled_microdollars: nil})
      |> Repo.update!()

    _envelope = recorded_envelope(invocation, entry)

    assert {:ok, reopened} = Reprocessor.reprocess(invocation.id, now: @now)
    assert reopened.stage == :thread_ready
    assert Repo.reload!(entry).state == :indeterminate
    assert [_job] = research_jobs(invocation)
  end

  test "reprocessing is one-shot and cannot enqueue duplicate work" do
    invocation = reprocessable_invocation(true, "one-shot")
    entry = recorded_attempt(invocation)
    _envelope = recorded_envelope(invocation, entry)

    assert {:ok, _reopened} = Reprocessor.reprocess(invocation.id, now: @now)
    assert {:error, :not_reprocessable} = Reprocessor.reprocess(invocation.id, now: @now)
    assert [_job] = research_jobs(invocation)
  end

  test "concurrent reprocessing requests produce one reopening and one job" do
    invocation = reprocessable_invocation(true, "concurrent")
    entry = recorded_attempt(invocation)
    _envelope = recorded_envelope(invocation, entry)
    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Reprocessor.reprocess(invocation.id, now: @now))
        end)
      end

    task_pids = for _index <- 1..2, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(task_pids, &send(&1, :go))
    results = Task.await_many(tasks)

    assert Enum.count(results, &match?({:ok, %Invocation{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_reprocessable})) == 1
    assert [_job] = research_jobs(invocation)
  end

  test "inserts distinct replay work while the failed worker job is still executing" do
    invocation = reprocessable_invocation(true, "executing-old-job")
    entry = recorded_attempt(invocation)
    _envelope = recorded_envelope(invocation, entry)

    old_job =
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
      |> Oban.Job.new(worker: ContextBot.Workers.ResearchWorker, queue: :dry_research)
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{
        state: "executing",
        attempted_at: @now,
        attempted_by: ["old-node"]
      })
      |> Repo.update!()

    assert {:ok, _reopened} = Reprocessor.reprocess(invocation.id, now: @now)

    assert [persisted_old, replay] = research_jobs(invocation)
    assert persisted_old.id == old_job.id
    assert persisted_old.state == "executing"
    assert replay.state == "available"
    assert is_binary(replay.args["reprocess_token"])
    assert replay.args["reprocess_token"] != ""
  end

  test "rejects missing, nonterminal, and non-provider failures" do
    assert {:error, :not_found} = Reprocessor.reprocess(999_999, now: @now)

    nonterminal = reprocessable_invocation(true, "nonterminal")

    nonterminal
    |> Invocation.transition_changeset(%{status: :thread_ready, stage: :thread_ready})
    |> Repo.update!()

    assert {:error, :not_reprocessable} = Reprocessor.reprocess(nonterminal.id, now: @now)

    wrong_failure = reprocessable_invocation(true, "wrong-failure")

    wrong_failure
    |> Invocation.transition_changeset(%{failure_category: :thread_unavailable})
    |> Repo.update!()

    assert {:error, :not_reprocessable} = Reprocessor.reprocess(wrong_failure.id, now: @now)
  end

  test "rejects missing durable request or canonical thread" do
    missing_request = reprocessable_invocation(true, "missing-request")

    missing_request
    |> Invocation.transition_changeset(%{anthropic_messages: nil})
    |> Repo.update!()

    missing_thread = reprocessable_invocation(true, "missing-thread")

    missing_thread
    |> Invocation.transition_changeset(%{canonical_thread: nil})
    |> Repo.update!()

    assert {:error, :not_reprocessable} = Reprocessor.reprocess(missing_request.id, now: @now)
    assert {:error, :not_reprocessable} = Reprocessor.reprocess(missing_thread.id, now: @now)
  end

  test "rejects attempts without a complete latest response envelope" do
    no_attempt = reprocessable_invocation(true, "no-attempt")
    assert {:error, :missing_recorded_response} = Reprocessor.reprocess(no_attempt.id, now: @now)

    missing_envelope = reprocessable_invocation(true, "missing-envelope")
    _entry = recorded_attempt(missing_envelope)

    assert {:error, :missing_recorded_response} =
             Reprocessor.reprocess(missing_envelope.id, now: @now)
  end

  test "rejects any exposed attempt whose response was not retained" do
    invocation = reprocessable_invocation(true, "ambiguous")
    recorded = recorded_attempt(invocation, "recorded")
    _envelope = recorded_envelope(invocation, recorded)
    _ambiguous = unrecorded_attempt(invocation)

    assert {:error, :ambiguous_provider_attempt} =
             Reprocessor.reprocess(invocation.id, now: @now)
  end

  test "rejects non-success and malformed retained provider bodies" do
    for {suffix, status, body} <- [
          {"http-error", 500, ~s({"type":"error"})},
          {"malformed", 200, "not-json"},
          {"json-list", 200, "[]"}
        ] do
      invocation = reprocessable_invocation(true, suffix)
      entry = recorded_attempt(invocation)
      _envelope = recorded_envelope(invocation, entry, status, body)

      assert {:error, :invalid_recorded_response} =
               Reprocessor.reprocess(invocation.id, now: @now)
    end
  end

  defp reprocessable_invocation(dry_run, suffix) do
    uri = if(dry_run, do: "local://reprocessor/#{suffix}", else: public_uri(suffix))
    cid = "bafy-reprocessor-#{suffix}"

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: dry_run,
      target_uri: if(dry_run, do: public_uri("target-#{suffix}")),
      invocation_text: if(dry_run, do: "Question?"),
      invocation_uri: uri,
      notification_cid: cid,
      current_cid: cid,
      actor_did: if(dry_run, do: "local:operator", else: "did:plc:actor"),
      raw_notification: %{"source" => "test"},
      received_at: @now,
      status: :failed,
      stage: :failed,
      canonical_thread: "CONTEXT_BOT_THREAD_V2\n\n[image 1] Alt text: Evidence",
      canonical_thread_version: "2",
      canonical_media: [
        %{
          "type" => "image",
          "index" => 1,
          "post_uri" => public_uri("target-#{suffix}"),
          "url" =>
            "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:actor/bafkrei#{suffix}@jpeg",
          "alt" => "Evidence"
        }
      ],
      anthropic_messages: %{
        "model" => "claude-sonnet-5",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "image",
                "source" => %{
                  "type" => "url",
                  "url" =>
                    "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:actor/bafkrei#{suffix}@jpeg"
                }
              },
              %{
                "type" => "text",
                "text" => "CONTEXT_BOT_THREAD_V2\n\n[image 1] Alt text: Evidence"
              }
            ]
          }
        ]
      },
      anthropic_usage: %{"totals" => %{"input_tokens" => 14, "output_tokens" => 337}},
      failure_category: :provider_response,
      failure_detail: %{"reason" => "unexpected_tool_use"},
      research_claim_token: "old-owner",
      research_claimed_at: @now,
      publication_claim_token: "old-publisher",
      publication_claimed_at: @now,
      defer_until: @now,
      deferred_attempt_kind: :repair,
      completed_at: @now
    })
    |> Repo.insert!()
  end

  defp recorded_attempt(invocation, suffix \\ "latest") do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "reprocessor-#{invocation.id}-#{suffix}",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: :research,
      reserved_microdollars: 5_000_000,
      settled_microdollars: 102_223,
      state: :settled,
      usage: %{"input_tokens" => 14, "output_tokens" => 337},
      pricing_version: "sonnet-5-2026-07-28",
      sent_at: @now,
      response_recorded_at: @now,
      research_claim_token: "old-owner"
    })
    |> Repo.insert!()
  end

  defp unrecorded_attempt(invocation) do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "reprocessor-#{invocation.id}-ambiguous",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: :retry,
      reserved_microdollars: 5_000_000,
      state: :sent,
      sent_at: @now,
      research_claim_token: "old-owner"
    })
    |> Repo.insert!()
  end

  defp recorded_envelope(invocation, entry, status \\ 200, body \\ ~s({"type":"message"})) do
    metadata_blob =
      :erlang.term_to_binary(%{
        status: status,
        attempt_key: entry.attempt_key,
        kind: entry.kind
      })

    %ResponseEnvelope{}
    |> ResponseEnvelope.changeset(%{
      invocation_id: invocation.id,
      budget_entry_id: entry.id,
      attempt_key: entry.attempt_key,
      kind: entry.kind,
      status: status,
      metadata_blob: metadata_blob,
      raw_body: body,
      received_at: @now,
      duration_ms: 44_000,
      storage_bytes: byte_size(metadata_blob) + byte_size(body)
    })
    |> Repo.insert!()
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

  defp public_uri(suffix),
    do: "at://did:plc:actor/app.bsky.feed.post/#{suffix}"
end
