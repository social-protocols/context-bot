defmodule ContextBot.Workflow.ReenqueuerTest do
  use ContextBot.DataCase, async: false

  import Ecto.Query

  alias ContextBot.Research.{BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workflow.{Invocation, Reenqueuer}

  @now ~U[2026-09-03 00:00:00.000000Z]

  test "reenqueues a failed provider_response with a retained envelope as a fresh attempt" do
    invocation = failed_invocation(true, "with-envelope")
    entry = recorded_attempt(invocation)

    envelope =
      recorded_envelope(
        invocation,
        entry,
        400,
        ~s({"type":"error","error":{"type":"invalid_request_error"}})
      )

    original_sequence = invocation.anthropic_attempt_sequence
    original_uri = invocation.invocation_uri
    original_cid = invocation.notification_cid
    original_actor = invocation.actor_did
    original_thread = invocation.canonical_thread
    original_media = invocation.canonical_media
    original_eligibility = invocation.eligibility_method

    assert {:ok, reopened} = Reenqueuer.reenqueue(invocation.id, now: @now)

    assert reopened.id == invocation.id
    assert reopened.status == :thread_ready
    assert reopened.stage == :thread_ready
    assert reopened.anthropic_messages == nil
    assert reopened.anthropic_usage == nil
    assert reopened.citation_sources == []
    assert reopened.full_response == nil
    assert reopened.selected_reply == nil
    assert reopened.reply_validation == nil
    assert reopened.no_reply == false
    assert reopened.standard_site_document_uri == nil
    assert reopened.standard_site_document_rkey == nil
    assert reopened.reader_ready_at == nil
    assert reopened.reader_checked_at == nil
    assert reopened.reply_repo == nil
    assert reopened.reply_rkey == nil
    assert reopened.reply_record == nil
    assert reopened.reply_part2_rkey == nil
    assert reopened.reply_part2_record == nil
    assert reopened.reply_part3_rkey == nil
    assert reopened.reply_part3_record == nil
    assert reopened.reply_uri == nil
    assert reopened.reply_cid == nil
    assert reopened.reply_part2_uri == nil
    assert reopened.reply_part2_cid == nil
    assert reopened.reply_part3_uri == nil
    assert reopened.reply_part3_cid == nil
    assert reopened.follower_post_rkey == nil
    assert reopened.follower_post_record == nil
    assert reopened.follower_post_uri == nil
    assert reopened.follower_post_cid == nil
    assert reopened.publication_claim_token == nil
    assert reopened.publication_claimed_at == nil
    assert reopened.research_claim_token == nil
    assert reopened.research_claimed_at == nil
    assert reopened.failure_category == nil
    assert reopened.failure_detail == nil
    assert reopened.completed_at == nil
    assert reopened.defer_until == nil
    assert reopened.deferred_attempt_kind == nil
    assert reopened.anthropic_attempt_sequence == original_sequence
    assert reopened.invocation_uri == original_uri
    assert reopened.notification_cid == original_cid
    assert reopened.actor_did == original_actor
    assert reopened.canonical_thread == original_thread
    assert reopened.canonical_media == original_media
    assert reopened.eligibility_method == original_eligibility
    assert reopened.dry_run == true
    assert reopened.raw_thread == invocation.raw_thread

    assert Repo.get!(BudgetEntry, entry.id).state == :settled
    assert Repo.get!(ResponseEnvelope, envelope.id).raw_body == envelope.raw_body
    assert [job] = research_jobs(invocation)
    assert job.state == "available"
    assert job.queue == "dry_research"
    assert job.args["new_attempt"] == true
    assert is_binary(job.args["reenqueue_token"])
    assert job.args["reenqueue_token"] != ""
    assert job.args["uri"] == original_uri
    assert job.args["cid"] == original_cid
  end

  test "reenqueues a failed provider_response that has no recorded envelope" do
    invocation = failed_invocation(true, "no-envelope")

    assert {:ok, reopened} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert reopened.status == :thread_ready
    assert reopened.stage == :thread_ready
    assert reopened.anthropic_messages == nil
    assert [job] = research_jobs(invocation)
    assert job.args["new_attempt"] == true
  end

  test "uses the public research queue for a public invocation" do
    invocation = failed_invocation(false, "public-failed")

    assert {:ok, _reopened} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert [job] = research_jobs(invocation)
    assert job.queue == "research"
    assert job.args["new_attempt"] == true
  end

  test "reenqueues an unpublished complete invocation and clears the research checkpoint" do
    invocation = unpublished_complete(true, "complete-unpublished")
    entry = recorded_attempt(invocation)
    envelope = recorded_envelope(invocation, entry)

    assert {:ok, reopened} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert reopened.status == :thread_ready
    assert reopened.stage == :thread_ready
    assert reopened.anthropic_messages == nil
    assert reopened.full_response == nil
    assert reopened.selected_reply == nil
    assert reopened.completed_at == nil
    assert Repo.get!(BudgetEntry, entry.id).id == entry.id
    assert Repo.get!(ResponseEnvelope, envelope.id).id == envelope.id
    assert [job] = research_jobs(invocation)
    assert job.args["new_attempt"] == true
  end

  test "reenqueue is one-shot and cannot enqueue duplicate work" do
    invocation = failed_invocation(true, "one-shot")

    assert {:ok, _reopened} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert {:error, :not_reenqueueable} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert [_job] = research_jobs(invocation)
  end

  test "concurrent reenqueue requests produce one reset and one job" do
    invocation = failed_invocation(true, "concurrent")
    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Reenqueuer.reenqueue(invocation.id, now: @now))
        end)
      end

    task_pids = for _index <- 1..2, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(task_pids, &send(&1, :go))
    results = Task.await_many(tasks)

    assert Enum.count(results, &match?({:ok, %Invocation{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_reenqueueable})) == 1
    assert [_job] = research_jobs(invocation)
  end

  test "does not mutate a neighboring invocation" do
    target = failed_invocation(true, "target")
    neighbor = failed_invocation(true, "neighbor")
    neighbor_messages = neighbor.anthropic_messages
    neighbor_status = neighbor.status

    assert {:ok, _reopened} = Reenqueuer.reenqueue(target.id, now: @now)

    persisted = Repo.reload!(neighbor)
    assert persisted.status == neighbor_status
    assert persisted.anthropic_messages == neighbor_messages
    assert research_jobs(neighbor) == []
  end

  test "rejects a missing invocation" do
    assert {:error, :not_found} = Reenqueuer.reenqueue(999_999, now: @now)
  end

  test "rejects a published reply_uri" do
    invocation = failed_invocation(false, "already-published")
    reply_uri = public_uri("existing-reply")

    invocation
    |> Invocation.transition_changeset(%{reply_uri: reply_uri, reply_cid: "bafy-existing-reply"})
    |> Repo.update!()

    assert {:error, :already_published} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert Repo.reload!(invocation).reply_uri == reply_uri
    assert Repo.reload!(invocation).status == :failed
    assert research_jobs(invocation) == []
  end

  test "rejects a published part2 or part3 uri even without reply_uri" do
    part2 = failed_invocation(false, "published-part2")

    part2
    |> Invocation.transition_changeset(%{reply_part2_uri: public_uri("part2")})
    |> Repo.update!()

    assert {:error, :already_published} = Reenqueuer.reenqueue(part2.id, now: @now)
    assert research_jobs(part2) == []

    part3 = failed_invocation(false, "published-part3")

    part3
    |> Invocation.transition_changeset(%{reply_part3_uri: public_uri("part3")})
    |> Repo.update!()

    assert {:error, :already_published} = Reenqueuer.reenqueue(part3.id, now: @now)
    assert research_jobs(part3) == []

    follower = failed_invocation(false, "published-follower")

    follower
    |> Invocation.transition_changeset(%{follower_post_uri: public_uri("follower")})
    |> Repo.update!()

    assert {:error, :already_published} = Reenqueuer.reenqueue(follower.id, now: @now)
    assert research_jobs(follower) == []
  end

  test "rejects a complete invocation that already has a published reply" do
    invocation = published_complete(false, "complete-published")

    assert {:error, :already_published} = Reenqueuer.reenqueue(invocation.id, now: @now)
    assert Repo.reload!(invocation).status == :complete
    assert Repo.reload!(invocation).reply_uri == invocation.reply_uri
    assert research_jobs(invocation) == []
  end

  test "rejects an in-flight provider attempt inside the HTTP timeout" do
    invocation = failed_invocation(true, "inflight")
    _entry = unrecorded_attempt(invocation)

    assert {:error, :ambiguous_provider_attempt} =
             Reenqueuer.reenqueue(invocation.id, now: @now)

    assert Repo.reload!(invocation).status == :failed
    assert research_jobs(invocation) == []
  end

  test "reenqueues after the HTTP timeout even when an unrecorded attempt remains" do
    invocation = failed_invocation(true, "elapsed-inflight")
    _entry = unrecorded_attempt(invocation)
    later = DateTime.add(@now, 301, :second)

    assert {:ok, reopened} = Reenqueuer.reenqueue(invocation.id, now: later)
    assert reopened.stage == :thread_ready
    assert [job] = research_jobs(invocation)
    assert job.args["new_attempt"] == true
  end

  test "rejects nonterminal stages and failures without a canonical thread" do
    nonterminal = failed_invocation(true, "nonterminal")

    nonterminal
    |> Invocation.transition_changeset(%{status: :thread_ready, stage: :thread_ready})
    |> Repo.update!()

    assert {:error, :not_reenqueueable} = Reenqueuer.reenqueue(nonterminal.id, now: @now)

    missing_thread = failed_invocation(true, "missing-thread")

    missing_thread
    |> Invocation.transition_changeset(%{canonical_thread: nil})
    |> Repo.update!()

    assert {:error, :not_reenqueueable} = Reenqueuer.reenqueue(missing_thread.id, now: @now)
    assert research_jobs(nonterminal) == []
    assert research_jobs(missing_thread) == []
  end

  defp failed_invocation(dry_run, suffix) do
    uri = if(dry_run, do: "local://reenqueuer/#{suffix}", else: public_uri(suffix))
    cid = "bafy-reenqueuer-#{suffix}"

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: dry_run,
      target_uri: if(dry_run, do: public_uri("target-#{suffix}")),
      invocation_text: if(dry_run, do: "Question?"),
      invocation_uri: uri,
      notification_cid: cid,
      current_cid: cid,
      actor_did: if(dry_run, do: "local:operator", else: "did:plc:actor"),
      actor_handle: if(dry_run, do: nil, else: "actor.bsky.social"),
      raw_notification: %{"source" => "test"},
      received_at: @now,
      status: :failed,
      stage: :failed,
      eligibility_method: if(dry_run, do: nil, else: "public"),
      eligibility_evidence: if(dry_run, do: nil, else: %{"tier" => "public"}),
      raw_thread: %{"posts" => [%{"uri" => uri}]},
      canonical_thread: "CONTEXT_BOT_THREAD_V2\n\nQuestion about #{suffix}",
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
        "output_config" => %{"format" => %{"type" => "json_schema"}},
        "messages" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "old V9 body"}]
          }
        ]
      },
      anthropic_attempt_sequence: 3,
      anthropic_usage: %{"totals" => %{"input_tokens" => 14, "output_tokens" => 337}},
      citation_sources: [%{"url" => "https://example.test/#{suffix}"}],
      full_response: "old writeup",
      selected_reply: "old compact",
      reply_validation: %{"result" => "ok"},
      no_reply: false,
      standard_site_document_uri: "at://did:plc:bot/site.standard.document/#{suffix}",
      standard_site_document_rkey: "doc#{suffix}",
      reader_ready_at: @now,
      reader_checked_at: @now,
      failure_category: :provider_response,
      failure_detail: %{"reason" => "provider_http_error", "status" => 400},
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

  defp unpublished_complete(dry_run, suffix) do
    suffix
    |> then(&failed_invocation(dry_run, &1))
    |> Invocation.transition_changeset(%{
      status: :complete,
      stage: :complete,
      failure_category: nil,
      failure_detail: nil
    })
    |> Repo.update!()
  end

  defp published_complete(dry_run, suffix) do
    suffix
    |> then(&unpublished_complete(dry_run, &1))
    |> Invocation.transition_changeset(%{
      reply_uri: public_uri("reply-#{suffix}"),
      reply_cid: "bafy-reply-#{suffix}",
      reply_part2_uri: public_uri("reply-part2-#{suffix}"),
      reply_part2_cid: "bafy-reply-part2-#{suffix}"
    })
    |> Repo.update!()
  end

  defp recorded_attempt(invocation, suffix \\ "latest") do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "reenqueuer-#{invocation.id}-#{suffix}",
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
      attempt_key: "reenqueuer-#{invocation.id}-ambiguous",
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
