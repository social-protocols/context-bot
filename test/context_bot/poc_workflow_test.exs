defmodule ContextBot.POCWorkflowTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.POCFixture
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.Invocation
  alias ContextBot.Workflow.Store

  setup {Req.Test, :verify_on_exit!}

  test "an eligible direct public mention durably becomes one ancestor-informed reply" do
    test_pid = self()

    fixture =
      POCFixture.start!(
        observer: fn
          :anthropic_post ->
            invocation = POCFixture.invocation!()

            send(test_pid, {
              :before_anthropic,
              invocation.stage,
              invocation.raw_thread,
              Store.anthropic_responses(invocation)
            })

          :pds_put ->
            invocation = POCFixture.invocation!()

            send(test_pid, {
              :before_pds_put,
              invocation.stage,
              invocation.reply_record,
              invocation.reply_cid
            })

          _endpoint ->
            :ok
        end
      )

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility, :thread, :research, :reply])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :complete
    assert invocation.eligibility_method == "operator_allowlist"
    assert invocation.canonical_thread =~ "The root claim."
    assert invocation.canonical_thread =~ "The immediate parent claim."
    assert invocation.canonical_thread =~ "@contextbot.test please add context."
    refute invocation.canonical_thread =~ "DESCENDANT"

    assert_received {:before_anthropic, :researching, raw_thread, []}
    assert raw_thread == POCFixture.thread_fixture()
    assert_received {:before_pds_put, :publishing, reply_record, nil}
    assert reply_record == invocation.reply_record

    [request] = POCFixture.anthropic_requests(fixture)
    [message] = request["messages"]
    assert message["content"] == invocation.canonical_thread
    refute message["content"] =~ "DESCENDANT"

    assert [response] = Store.anthropic_responses(invocation)
    assert response.raw_body == POCFixture.anthropic_fixture("tool_success.json")
    assert [%BudgetEntry{state: :settled}] = Repo.all(BudgetEntry)

    assert invocation.selected_reply == "Useful context from primary sources."
    assert String.length(invocation.selected_reply) <= 300
    assert byte_size(invocation.selected_reply) <= 3_000

    assert invocation.reply_record["reply"]["parent"] == %{
             "uri" => invocation.invocation_uri,
             "cid" => invocation.current_cid
           }

    assert invocation.reply_record["reply"]["root"] == %{
             "uri" => invocation.root_uri,
             "cid" => invocation.root_cid
           }

    assert POCFixture.created_reply_count(fixture) == 1
    assert POCFixture.visible_reply(fixture)["value"] == invocation.reply_record

    notification_call = Enum.find(POCFixture.calls(fixture), &(&1.endpoint == :notifications))

    assert notification_call.query == %{
             "limit" => "100",
             "priority" => "false",
             "reasons" => "mention"
           }

    thread_call = Enum.find(POCFixture.calls(fixture), &(&1.endpoint == :thread))

    assert thread_call.query == %{
             "depth" => "0",
             "parentHeight" => "80",
             "uri" => invocation.invocation_uri
           }
  end

  test "operator allowlisting bypasses identity HTTP" do
    fixture = POCFixture.start!()
    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    assert POCFixture.invocation!().stage == :capturing_thread
    assert POCFixture.call_count(fixture, :profile) == 0
    assert POCFixture.call_count(fixture, :thread) == 0
    assert POCFixture.call_count(fixture, :anthropic_post) == 0
    assert POCFixture.created_reply_count(fixture) == 0
  end

  test "authoritative Elder absence makes an ordinary actor ineligible and silent" do
    fixture = POCFixture.start!(eligibility: :ineligible)
    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :ineligible
    assert invocation.completed_at
    assert POCFixture.call_count(fixture, :profile) == 1
    refute_downstream_calls(fixture)
  end

  test "a valid Elder label authorizes the mention" do
    fixture = POCFixture.start!(eligibility: :elder)
    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :capturing_thread
    assert invocation.eligibility_method == "bluesky_elder"
    assert POCFixture.call_count(fixture, :profile) == 1
    refute_downstream_calls(fixture)
  end

  test "a bidirectionally verified bsky.team identity authorizes the mention" do
    actor_did = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"

    fixture =
      POCFixture.start!(
        eligibility: :team,
        actor_did: actor_did,
        actor_handle: "alice.bsky.team"
      )

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :capturing_thread
    assert invocation.eligibility_method == "bsky_team"
    assert POCFixture.call_count(fixture, :profile) == 1
    assert POCFixture.call_count(fixture, :resolve_handle) == 1
    assert POCFixture.call_count(fixture, :resolve_did) == 1
    refute_downstream_calls(fixture)
  end

  test "an unconfirmed Elder response remains retryable and starts no downstream work" do
    fixture = POCFixture.start!(eligibility: :invalid_elder_header)
    POCFixture.poll_once!(fixture)

    assert {{:error, :labeler_unavailable}, _job} =
             POCFixture.perform_next(fixture, :eligibility)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :checking_eligibility
    assert invocation.failure_category == nil
    refute_downstream_calls(fixture)
  end

  test "a stale bsky.team forward identity is ineligible and silent" do
    fixture =
      POCFixture.start!(
        eligibility: :stale_team,
        actor_did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        actor_handle: "alice.bsky.team"
      )

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    assert POCFixture.invocation!().stage == :ineligible
    assert POCFixture.call_count(fixture, :resolve_handle) == 1
    assert POCFixture.call_count(fixture, :resolve_did) == 0
    refute_downstream_calls(fixture)
  end

  test "the actor rolling limit defers before thread or provider HTTP" do
    fixture = POCFixture.start!(settings: [actor_hourly_limit: 1])
    insert_invocation!("history-actor", "did:plc:alice", :complete, admitted_at: now())

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    assert POCFixture.invocation!().stage == :deferred_rate
    refute_downstream_calls(fixture)
  end

  test "the global rolling limit defers before thread or provider HTTP" do
    fixture = POCFixture.start!(settings: [global_hourly_limit: 1])
    insert_invocation!("history-global", "did:plc:other", :complete, admitted_at: now())

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility])

    assert POCFixture.invocation!().stage == :deferred_rate
    refute_downstream_calls(fixture)
  end

  test "pending capacity is durable but starts no authorization or downstream HTTP" do
    fixture = POCFixture.start!(settings: [max_pending: 1])
    insert_invocation!("pending", "did:plc:other", :received)

    POCFixture.poll_once!(fixture)

    invocation =
      Repo.get_by!(Invocation,
        invocation_uri: "at://did:plc:alice/app.bsky.feed.post/invocation"
      )

    assert invocation.stage == :deferred_capacity
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert POCFixture.call_count(fixture, :profile) == 0
    refute_downstream_calls(fixture)
  end

  test "daily budget exhaustion defers before Anthropic or publication HTTP" do
    fixture = POCFixture.start!(settings: [anthropic_daily_budget_usd: "5.000000"])
    historical = insert_invocation!("budget-history", "did:plc:other", :complete)

    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "prior-day-charge",
      invocation_id: historical.id,
      budget_date: DateTime.to_date(now()),
      kind: :research,
      reserved_microdollars: 5_000_000,
      state: :reserved
    })
    |> Repo.insert!()

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility, :thread, :research])

    assert POCFixture.invocation!().stage == :deferred_budget
    assert Repo.aggregate(BudgetEntry, :count) == 1
    assert POCFixture.call_count(fixture, :anthropic_post) == 0
    assert POCFixture.call_count(fixture, :pds_put) == 0
    assert POCFixture.created_reply_count(fixture) == 0
  end

  test "duplicate polls, repeated jobs, restarts, and ambiguous writes converge once" do
    success = POCFixture.anthropic_fixture("tool_success.json")

    fixture =
      POCFixture.start!(
        anthropic_results: [
          {:transport, :timeout},
          {:response, 200, success, %{}}
        ],
        pds_mode: :ambiguous_once
      )

    POCFixture.poll_once!(fixture)
    POCFixture.poll_once!(fixture)
    assert Repo.aggregate(Invocation, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1

    eligibility_job = run_stage_twice!(fixture, :eligibility)
    POCFixture.restart_session!(fixture)
    POCFixture.poll_once!(fixture)
    assert :ok = POCFixture.perform_job(fixture, eligibility_job)

    thread_job = run_stage_twice!(fixture, :thread)
    POCFixture.restart_session!(fixture)
    POCFixture.poll_once!(fixture)
    assert :ok = POCFixture.perform_job(fixture, thread_job)

    research_job = run_stage_twice!(fixture, :research)
    POCFixture.restart_session!(fixture)
    POCFixture.poll_once!(fixture)
    assert :ok = POCFixture.perform_job(fixture, research_job)

    reply_job = run_stage_twice!(fixture, :reply)
    assert :ok = POCFixture.perform_job(fixture, reply_job)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :complete
    assert POCFixture.call_count(fixture, :notifications) == 5
    assert POCFixture.call_count(fixture, :session_create) == 4
    assert POCFixture.call_count(fixture, :anthropic_post) == 2
    assert POCFixture.created_reply_count(fixture) == 1
    assert POCFixture.call_count(fixture, :pds_put) == 1

    assert Enum.map(Repo.all(from entry in BudgetEntry, order_by: entry.id), & &1.state) == [
             :indeterminate,
             :settled
           ]

    assert [response] = Store.anthropic_responses(invocation)
    assert response.raw_body == success
    assert POCFixture.visible_reply(fixture)["value"] == invocation.reply_record
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a refusal is retained, categorized, and silent" do
    body = POCFixture.anthropic_fixture("refusal.json")
    fixture = POCFixture.start!(anthropic_results: [{:response, 200, body, %{}}])
    run_through_research!(fixture)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :provider_response
    assert [response] = Store.anthropic_responses(invocation)
    assert response.raw_body == body
    refute_publication(fixture)
  end

  test "malformed provider JSON is retained, categorized, and silent" do
    body = "{not-json"
    fixture = POCFixture.start!(anthropic_results: [{:response, 200, body, %{}}])
    run_through_research!(fixture)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :provider_response
    assert [response] = Store.anthropic_responses(invocation)
    assert response.raw_body == body
    refute_publication(fixture)
  end

  test "an oversized Anthropic response is rejected and produces no error reply" do
    limit = 10_000
    body = String.duplicate("x", limit + 1)

    fixture =
      POCFixture.start!(
        settings: [max_response_bytes: limit, max_storage_bytes: 100_000],
        anthropic_results: [{:response, 200, body, %{}}]
      )

    run_through_research!(fixture)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :provider_response
    assert invocation.failure_detail == %{"reason" => "provider_response_too_large"}
    assert Store.anthropic_responses(invocation) == []
    assert [%BudgetEntry{state: :indeterminate}] = Repo.all(BudgetEntry)
    refute_publication(fixture)
  end

  test "an unavailable target is categorized before research and remains silent" do
    fixture =
      POCFixture.start!(
        thread_result:
          {:json, 400, %{"error" => "RecordNotFound", "message" => "record not found"}}
      )

    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility, :thread])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :thread_unavailable
    assert POCFixture.call_count(fixture, :anthropic_post) == 0
    refute_publication(fixture)
  end

  test "a conflicting frozen publication target fails silently without overwriting it" do
    fixture = POCFixture.start!(pds_mode: :conflict)
    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility, :thread, :research, :reply])

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :publication_conflict
    assert invocation.failure_detail == %{"reason" => "record_mismatch"}
    assert POCFixture.call_count(fixture, :pds_put) == 0
    assert POCFixture.created_reply_count(fixture) == 0
  end

  test "exhausted provider retries retain every returned response and stay silent" do
    error_body = POCFixture.anthropic_fixture("error.json")

    fixture =
      POCFixture.start!(
        anthropic_results:
          List.duplicate({:response, 500, error_body, %{"retry-after" => "0"}}, 3)
      )

    run_through_research!(fixture)

    invocation = POCFixture.invocation!()
    assert invocation.stage == :failed
    assert invocation.failure_category == :provider_response
    assert invocation.failure_detail == %{"reason" => "provider_retries_exhausted"}

    assert Enum.map(Store.anthropic_responses(invocation), & &1.raw_body) ==
             List.duplicate(error_body, 3)

    assert Repo.aggregate(BudgetEntry, :count) == 3
    refute_publication(fixture)
  end

  defp run_through_research!(fixture) do
    POCFixture.poll_once!(fixture)
    POCFixture.drain_successfully!(fixture, [:eligibility, :thread, :research])
  end

  defp run_stage_twice!(fixture, queue) do
    job = POCFixture.job!(queue)
    assert :ok = POCFixture.perform_job(fixture, job)
    Repo.delete!(job)
    assert :ok = POCFixture.perform_job(fixture, job)
    job
  end

  defp refute_downstream_calls(fixture) do
    assert POCFixture.call_count(fixture, :thread) == 0
    assert POCFixture.call_count(fixture, :anthropic_post) == 0
    assert POCFixture.call_count(fixture, :pds_get) == 0
    assert POCFixture.call_count(fixture, :pds_put) == 0
  end

  defp refute_publication(fixture) do
    assert POCFixture.call_count(fixture, :pds_get) == 0
    assert POCFixture.call_count(fixture, :pds_put) == 0
    assert POCFixture.created_reply_count(fixture) == 0
  end

  defp insert_invocation!(rkey, actor_did, stage, extra \\ []) do
    uri = "at://#{actor_did}/app.bsky.feed.post/#{rkey}"
    cid = "bafy-#{rkey}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: cid,
          actor_did: actor_did,
          actor_handle: "actor.test",
          raw_notification: %{"uri" => uri, "cid" => cid},
          received_at: DateTime.add(now(), -60, :second),
          status: stage,
          stage: stage,
          completed_at: if(stage in [:complete, :failed, :ineligible], do: now())
        },
        Map.new(extra)
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp now, do: ~U[2026-07-29 12:00:00.123456Z]
end
