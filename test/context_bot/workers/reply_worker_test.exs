defmodule ContextBot.Workers.ReplyWorkerTest.PDS do
  @moduledoc false

  alias ContextBot.Workers.ReplyWorkerTest.Remote

  def get_record(repo, collection, rkey) do
    config = Application.fetch_env!(:context_bot, __MODULE__)

    case maybe_run_hook(config[:get_hook]) do
      {:return, result} -> result
      _continue -> Remote.get(config[:remote], repo, collection, rkey)
    end
  end

  def put_record(repo, collection, rkey, record) do
    config = Application.fetch_env!(:context_bot, __MODULE__)

    case maybe_run_hook(config[:put_hook]) do
      {:return, result} -> result
      _continue -> Remote.put(config[:remote], repo, collection, rkey, record)
    end
  end

  defp maybe_run_hook(nil), do: :ok
  defp maybe_run_hook(hook), do: hook.()
end

defmodule ContextBot.Workers.ReplyWorkerTest.Remote do
  @moduledoc false

  use Agent

  def start_link(options) do
    Agent.start_link(fn ->
      %{
        get_results: Keyword.get(options, :get_results, []),
        put_results: Keyword.get(options, :put_results, []),
        calls: [],
        visible: Keyword.get(options, :visible),
        next_cid: Keyword.get(options, :next_cid, "bafy-remote-created")
      }
    end)
  end

  def get(remote, repo, collection, rkey) do
    Agent.get_and_update(remote, fn state ->
      call = {:get, repo, collection, rkey}
      {result, state} = next_get(state, repo, collection, rkey)
      {result, %{state | calls: [call | state.calls]}}
    end)
  end

  def put(remote, repo, collection, rkey, record) do
    Agent.get_and_update(remote, fn state ->
      call = {:put, repo, collection, rkey, record}
      {result, state} = next_put(state, repo, collection, rkey, record)
      {result, %{state | calls: [call | state.calls]}}
    end)
  end

  def snapshot(remote) do
    Agent.get(remote, fn state -> %{state | calls: Enum.reverse(state.calls)} end)
  end

  defp next_get(%{get_results: [result | rest]} = state, _repo, _collection, _rkey),
    do: {result, %{state | get_results: rest}}

  defp next_get(%{visible: nil} = state, _repo, _collection, _rkey),
    do: {{:error, :record_not_found}, state}

  defp next_get(%{visible: visible} = state, _repo, _collection, _rkey),
    do: {{:ok, 200, %{}, visible}, state}

  defp next_put(
         %{put_results: [{:exposed, result} | rest], visible: nil} = state,
         repo,
         collection,
         rkey,
         record
       ) do
    uri = "at://#{repo}/#{collection}/#{rkey}"
    visible = %{"uri" => uri, "cid" => state.next_cid, "value" => record}
    {result, %{state | put_results: rest, visible: visible}}
  end

  defp next_put(%{put_results: [result | rest]} = state, _repo, _collection, _rkey, _record),
    do: {result, %{state | put_results: rest}}

  defp next_put(%{visible: nil} = state, repo, collection, rkey, record) do
    uri = "at://#{repo}/#{collection}/#{rkey}"
    visible = %{"uri" => uri, "cid" => state.next_cid, "value" => record}
    response = %{"uri" => uri, "cid" => state.next_cid}

    {{:ok, 200, %{}, response}, %{state | visible: visible}}
  end

  defp next_put(state, _repo, _collection, _rkey, _record),
    do: {{:error, :invalid_swap}, state}
end

defmodule ContextBot.Workers.ReplyWorkerTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.Settings
  alias ContextBot.Workers.ReplyWorker
  alias ContextBot.Workers.ReplyWorkerTest.{PDS, Remote}
  alias ContextBot.Workflow.{Invocation, Store}

  @bot_did "did:plc:contextbot123"
  @collection "app.bsky.feed.post"
  @now ~U[2026-07-29 13:00:00.123456Z]
  @rkey "3mreplyrecord2a"

  setup do
    original_worker_config = Application.get_env(:context_bot, ReplyWorker, :missing)
    original_pds_config = Application.get_env(:context_bot, PDS, :missing)

    on_exit(fn ->
      restore_env(ReplyWorker, original_worker_config)
      restore_env(PDS, original_pds_config)
    end)

    :ok
  end

  test "logs a publication attempt without record or identity content" do
    invocation = invocation("logged-publication")
    _remote = configure_remote()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    assert log =~ "\"invocation_id\":#{invocation.id}"
    assert log =~ "\"stage\":\"publishing\""
    assert log =~ "\"attempt_kind\":\"publication\""
    refute log =~ invocation.invocation_uri
    refute log =~ @bot_did
    refute log =~ invocation.reply_record["text"]
  end

  test "a malformed dry-run publication intent is permanently ignored" do
    invocation =
      invocation("dry-run-defense", :reply_ready, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/selected",
        invocation_text: "Can you check this?"
      })

    remote = configure_remote()

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :reply_ready
    assert persisted.publication_claim_token == nil
    assert persisted.publication_claimed_at == nil
    assert Remote.snapshot(remote).calls == []
  end

  test "the workflow store refuses to grant a publication claim for a dry run" do
    invocation =
      invocation("dry-run-claim-defense", :reply_ready, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/selected",
        invocation_text: "What's missing?"
      })

    stale_before = DateTime.add(@now, -300, :second)

    assert {:error, :stale_stage} =
             Store.claim_publication(invocation, "must-not-claim", @now, stale_before)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :reply_ready
    assert persisted.publication_claim_token == nil
  end

  test "GETs the deterministic record before a create-only PUT and completes only after exact reconciliation" do
    invocation = invocation("create")
    remote_record = remote_record(invocation, "bafy-created")

    remote =
      configure_remote(
        get_results: [{:error, :record_not_found}, {:ok, 200, %{}, remote_record}],
        put_results: [
          {:ok, 200, %{}, %{"uri" => remote_record["uri"], "cid" => "untrusted-put-cid"}}
        ]
      )

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.status == :complete
    assert persisted.reply_uri == remote_record["uri"]
    assert persisted.reply_cid == "bafy-created"
    assert persisted.completed_at == @now

    assert Remote.snapshot(remote).calls == [
             {:get, @bot_did, @collection, @rkey},
             {:put, @bot_did, @collection, @rkey, invocation.reply_record},
             {:get, @bot_did, @collection, @rkey}
           ]
  end

  test "accepts an existing exact record and its remote CID without PUT" do
    invocation = invocation("existing")
    remote_record = remote_record(invocation, "bafy-existing")
    remote = configure_remote(get_results: [{:ok, 200, %{}, remote_record}])

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_uri == remote_record["uri"]
    assert persisted.reply_cid == "bafy-existing"
    assert Remote.snapshot(remote).calls == [{:get, @bot_did, @collection, @rkey}]
  end

  test "fails terminally when any repository coordinate or record field differs" do
    cases = [
      {"repo",
       fn body ->
         %{body | "uri" => "at://did:plc:other/#{@collection}/#{@rkey}"}
       end},
      {"collection",
       fn body ->
         %{body | "uri" => "at://#{@bot_did}/app.bsky.feed.like/#{@rkey}"}
       end},
      {"rkey",
       fn body ->
         %{body | "uri" => "at://#{@bot_did}/#{@collection}/3motherrecord2"}
       end},
      {"changed-field", fn body -> put_in(body, ["value", "text"], "not our reply") end},
      {"extra-field", fn body -> put_in(body, ["value", "unexpected"], true) end}
    ]

    for {suffix, mutate} <- cases do
      invocation = invocation("conflict-#{suffix}")
      conflicting = invocation |> remote_record("bafy-conflict") |> mutate.()
      remote = configure_remote(get_results: [{:ok, 200, %{}, conflicting}])

      assert :ok = perform(invocation)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.status == :failed
      assert persisted.failure_category == :publication_conflict
      assert persisted.failure_detail == %{"reason" => "record_mismatch"}
      assert persisted.reply_uri == nil
      assert persisted.reply_cid == nil
      assert persisted.completed_at == @now
      assert Remote.snapshot(remote).calls == [{:get, @bot_did, @collection, @rkey}]
      Repo.delete!(persisted)
    end
  end

  test "reconciles timeout and InvalidSwap PUT results through an exact GET" do
    for error <- [:timeout, :invalid_swap] do
      invocation = invocation("reconcile-#{error}")
      exact = remote_record(invocation, "bafy-#{error}")

      remote =
        configure_remote(
          get_results: [{:error, :record_not_found}, {:ok, 200, %{}, exact}],
          put_results: [{:error, error}]
        )

      assert :ok = perform(invocation)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :complete
      assert persisted.reply_uri == exact["uri"]
      assert persisted.reply_cid == exact["cid"]

      assert Remote.snapshot(remote).calls == [
               {:get, @bot_did, @collection, @rkey},
               {:put, @bot_did, @collection, @rkey, invocation.reply_record},
               {:get, @bot_did, @collection, @rkey}
             ]

      Repo.delete!(persisted)
    end
  end

  test "keeps the frozen rkey and full record across a bounded Oban retry" do
    invocation = invocation("retry")
    exact = remote_record(invocation, "bafy-retried")

    remote =
      configure_remote(
        get_results: [
          {:error, :record_not_found},
          {:error, :record_not_found},
          {:error, :record_not_found},
          {:ok, 200, %{}, exact}
        ],
        put_results: [{:error, :timeout}, {:error, :invalid_swap}]
      )

    assert {:error, :timeout} = perform(invocation, 1, 111)
    retryable = Repo.reload!(invocation)
    assert retryable.stage == :publishing
    assert retryable.reply_rkey == @rkey
    assert retryable.reply_record == invocation.reply_record

    assert :ok = perform(invocation, 2, 111)
    assert Repo.reload!(invocation).stage == :complete

    put_calls =
      remote
      |> Remote.snapshot()
      |> Map.fetch!(:calls)
      |> Enum.filter(&match?({:put, _, _, _, _}, &1))

    assert put_calls == [
             {:put, @bot_did, @collection, @rkey, invocation.reply_record},
             {:put, @bot_did, @collection, @rkey, invocation.reply_record}
           ]
  end

  test "records authorization failure as a finite operator-intervention state" do
    for {suffix, get_results, put_results} <- [
          {"get", [{:error, :unauthorized}], []},
          {"put", [{:error, :record_not_found}], [{:error, :session_unavailable}]}
        ] do
      invocation = invocation("auth-#{suffix}")
      remote = configure_remote(get_results: get_results, put_results: put_results)

      assert :ok = perform(invocation)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.status == :failed
      assert persisted.failure_category == :publication_auth
      assert persisted.failure_detail == %{"reason" => "authorization_required"}
      assert persisted.reply_uri == nil
      assert persisted.reply_cid == nil
      assert persisted.completed_at == @now
      assert Enum.count(Remote.snapshot(remote).calls, &match?({:put, _, _, _, _}, &1)) <= 1
      Repo.delete!(persisted)
    end
  end

  test "the final Oban attempt makes transient GET, PUT, and reconciliation exhaustion finite" do
    cases = [
      {"get", [{:error, :timeout}], []},
      {"put", [{:error, :record_not_found}], [{:error, {:transient, 503}}]},
      {"reconcile", [{:error, :record_not_found}, {:error, :timeout}], [{:error, :timeout}]}
    ]

    for {suffix, get_results, put_results} <- cases do
      invocation = invocation("exhausted-#{suffix}")
      configure_remote(get_results: get_results, put_results: put_results)

      assert :ok = perform(invocation, 10)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.status == :failed
      assert persisted.failure_category == :publication_conflict
      assert persisted.failure_detail == %{"reason" => "retry_exhausted"}
      assert persisted.reply_rkey == @rkey
      assert persisted.reply_record == invocation.reply_record
      assert persisted.reply_uri == nil
      assert persisted.reply_cid == nil
      assert persisted.completed_at == @now
      Repo.delete!(persisted)
    end
  end

  test "a live publication owner prevents a duplicate auth failure from racing an exact success" do
    invocation = invocation("fenced-race", :publishing)
    exact = remote_record(invocation, "bafy-fenced-race")
    test_pid = self()
    {:ok, visits} = Agent.start_link(fn -> 0 end)

    get_hook = fn ->
      visit = Agent.get_and_update(visits, fn count -> {count + 1, count + 1} end)

      case visit do
        1 ->
          send(test_pid, {:publication_get_waiting, self()})

          receive do
            :release_publication_get -> :ok
          end

        2 ->
          {:return, {:error, :unauthorized}}
      end
    end

    configure_remote(visible: exact, get_hook: get_hook)

    owner = Task.async(fn -> perform(invocation, 1, 501) end)
    assert_receive {:publication_get_waiting, owner_pid}

    duplicate = Task.async(fn -> perform(invocation, 10, 502) end)
    assert Task.await(duplicate) == :ok

    send(owner_pid, :release_publication_get)
    assert Task.await(owner) == :ok

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_cid == "bafy-fenced-race"
    assert persisted.failure_category == nil
    assert Agent.get(visits, & &1) == 1
  end

  test "the same job resumes a live publication lease while a duplicate remains blocked" do
    invocation = invocation("lease-resume", :publishing)
    exact = remote_record(invocation, "bafy-lease-resume")

    remote =
      configure_remote(get_results: [{:error, :timeout}, {:ok, 200, %{}, exact}])

    assert {:error, :timeout} = perform(invocation, 1, 601)
    claimed = Repo.reload!(invocation)
    assert Map.get(claimed, :publication_claim_token) == "publication-job-601"

    calls_after_crash = Remote.snapshot(remote).calls
    assert :ok = perform(invocation, 1, 602)
    assert Remote.snapshot(remote).calls == calls_after_crash

    assert :ok = perform(invocation, 2, 601)
    assert Repo.reload!(invocation).stage == :complete
  end

  test "a different job takes over a stale bounded publication lease" do
    invocation = invocation("stale-takeover", :publishing)
    exact = remote_record(invocation, "bafy-stale-takeover")

    configure_remote(get_results: [{:error, :timeout}, {:ok, 200, %{}, exact}])
    configure_worker(claim_lease_ms: 1_000)

    assert {:error, :timeout} = perform(invocation, 1, 701)
    assert Map.get(Repo.reload!(invocation), :publication_claim_token) == "publication-job-701"

    configure_worker(
      now: fn -> DateTime.add(@now, 1_001, :millisecond) end,
      claim_lease_ms: 1_000
    )

    assert :ok = perform(invocation, 2, 702)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_cid == "bafy-stale-takeover"
    assert Map.get(persisted, :publication_claim_token) == nil
  end

  test "a stale owner is fenced before PUT when takeover happens during its GET" do
    invocation = invocation("fenced-before-put", :publishing)
    takeover_now = DateTime.add(@now, 2_000, :millisecond)

    get_hook = fn ->
      assert {:ok, taken_over} =
               Store.claim_publication(
                 invocation,
                 "publication-job-1102",
                 takeover_now,
                 DateTime.add(takeover_now, -1_000, :millisecond)
               )

      assert taken_over.publication_claim_token == "publication-job-1102"
    end

    remote = configure_remote(get_hook: get_hook)
    configure_worker(claim_lease_ms: 1_000)

    assert :ok = perform(invocation, 1, 1_101)
    refute Enum.any?(Remote.snapshot(remote).calls, &match?({:put, _, _, _, _}, &1))

    pds_config = Application.fetch_env!(:context_bot, PDS)
    Application.put_env(:context_bot, PDS, Keyword.put(pds_config, :get_hook, nil))
    configure_worker(now: fn -> takeover_now end, claim_lease_ms: 1_000)

    assert :ok = perform(invocation, 2, 1_102)
    assert Repo.reload!(invocation).stage == :complete
    assert visible_count(remote) == 1
  end

  test "a stale in-flight auth loser cannot replace a takeover's exact completion" do
    invocation = invocation("stale-auth-race", :publishing)
    exact = remote_record(invocation, "bafy-stale-auth-race")
    takeover_now = DateTime.add(@now, 2_000, :millisecond)
    test_pid = self()
    {:ok, visits} = Agent.start_link(fn -> 0 end)

    get_hook = fn ->
      visit = Agent.get_and_update(visits, fn count -> {count + 1, count + 1} end)

      case visit do
        1 ->
          send(test_pid, {:stale_auth_get_waiting, self()})

          receive do
            :release_stale_auth_get -> {:return, {:error, :unauthorized}}
          end

        2 ->
          :ok
      end
    end

    configure_remote(visible: exact, get_hook: get_hook)
    configure_worker(claim_lease_ms: 1_000)

    old_owner = Task.async(fn -> perform(invocation, 10, 1_201) end)
    assert_receive {:stale_auth_get_waiting, old_pid}

    configure_worker(now: fn -> takeover_now end, claim_lease_ms: 1_000)
    assert :ok = perform(invocation, 1, 1_202)
    assert Repo.reload!(invocation).stage == :complete

    send(old_pid, :release_stale_auth_get)
    assert Task.await(old_owner) == :ok

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_cid == "bafy-stale-auth-race"
    assert persisted.failure_category == nil
  end

  test "a stale owner is fenced before reconciliation after an exposed PUT" do
    invocation = invocation("fenced-after-put", :publishing)
    takeover_now = DateTime.add(@now, 2_000, :millisecond)

    put_hook = fn ->
      assert {:ok, taken_over} =
               Store.claim_publication(
                 invocation,
                 "publication-job-1302",
                 takeover_now,
                 DateTime.add(takeover_now, -1_000, :millisecond)
               )

      assert taken_over.publication_claim_token == "publication-job-1302"
    end

    remote = configure_remote(put_hook: put_hook)
    configure_worker(claim_lease_ms: 1_000)

    assert :ok = perform(invocation, 1, 1_301)
    assert Repo.reload!(invocation).stage == :publishing
    assert visible_count(remote) == 1

    assert Enum.count(Remote.snapshot(remote).calls, &match?({:get, _, _, _}, &1)) == 1

    pds_config = Application.fetch_env!(:context_bot, PDS)
    Application.put_env(:context_bot, PDS, Keyword.put(pds_config, :put_hook, nil))
    configure_worker(now: fn -> takeover_now end, claim_lease_ms: 1_000)

    assert :ok = perform(invocation, 2, 1_302)
    assert Repo.reload!(invocation).stage == :complete
    assert Enum.count(Remote.snapshot(remote).calls, &match?({:put, _, _, _, _}, &1)) == 1
  end

  test "missing or corrupt frozen repos fail before any PDS I/O" do
    for {suffix, reply_repo} <- [{"missing", nil}, {"corrupt", "not-a-did"}] do
      invocation = invocation("invalid-repo-#{suffix}")

      Invocation
      |> where([stored], stored.id == ^invocation.id)
      |> Repo.update_all(set: [reply_repo: reply_repo])

      remote = configure_remote()
      assert :ok = perform(invocation, 1, 1_401)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.failure_category == :publication_conflict
      assert persisted.failure_detail == %{"reason" => "invalid_frozen_intent"}
      assert Remote.snapshot(remote).calls == []
      Repo.delete!(persisted)
    end
  end

  test "a retry keeps the frozen publication repo despite configured bot DID drift" do
    invocation = invocation("repo-drift")
    exact = remote_record(invocation, "bafy-repo-drift")

    remote =
      configure_remote(
        get_results: [
          {:error, :record_not_found},
          {:error, :record_not_found},
          {:ok, 200, %{}, exact}
        ],
        put_results: [{:error, :timeout}]
      )

    assert {:error, :timeout} = perform(invocation, 1, 801)

    configure_worker(settings: Settings.load(bot_did: "did:plc:driftedbot456"))

    assert :ok = perform(invocation, 2, 801)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert Map.get(persisted, :reply_repo) == @bot_did

    assert Enum.all?(Remote.snapshot(remote).calls, fn
             {_method, repo, _collection, _rkey} -> repo == @bot_did
             {:put, repo, _collection, _rkey, _record} -> repo == @bot_did
           end)
  end

  test "an exposed transport error reconciles the created record even on the final attempt" do
    invocation = invocation("exposed-transport")

    remote =
      configure_remote(put_results: [{:exposed, {:error, {:transient, :transport}}}])

    assert :ok = perform(invocation, 10, 901)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_cid == "bafy-remote-created"
    assert visible_count(remote) == 1
  end

  test "permanent 403 GET and PUT failures wait for operator authorization repair" do
    for {suffix, get_results, put_results} <- [
          {"get", [{:error, {:permanent, 403}}], []},
          {"put", [{:error, :record_not_found}], [{:error, {:permanent, 403}}]}
        ] do
      invocation = invocation("permanent-403-#{suffix}")
      configure_remote(get_results: get_results, put_results: put_results)

      assert :ok = perform(invocation, 1, 1_001)

      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.failure_category == :publication_auth
      assert persisted.failure_detail == %{"reason" => "authorization_required"}
      Repo.delete!(persisted)
    end
  end

  test "contextual backoff preserves strict Retry-After seconds and bounds malformed values" do
    assert ReplyWorker.backoff(rate_limited_job("47")) == 47
    assert ReplyWorker.backoff(rate_limited_job(" 47")) == 15
    assert ReplyWorker.backoff(rate_limited_job("47 ")) == 15
    assert ReplyWorker.backoff(rate_limited_job("999999")) == 3_600
    assert ReplyWorker.backoff(rate_limited_job("999999999999999999999999999999999999")) == 3_600
    assert ReplyWorker.backoff(rate_limited_job("47 seconds")) == 15
    assert ReplyWorker.backoff(rate_limited_job(nil)) == 15
  end

  test "contextual backoff rejects a plus-signed Retry-After value" do
    assert ReplyWorker.backoff(rate_limited_job("+47")) == 15
  end

  test "contextual backoff rejects a minus-signed zero Retry-After value" do
    assert ReplyWorker.backoff(rate_limited_job("-0")) == 15
  end

  test "repeated completed jobs never issue another PDS request" do
    invocation = invocation("repeated")
    remote = configure_remote()

    assert :ok = perform(invocation)
    initial_calls = Remote.snapshot(remote).calls
    assert :ok = perform(invocation)
    assert Remote.snapshot(remote).calls == initial_calls
    assert visible_count(remote) == 1
  end

  test "concurrent resumptions create at most one visible deterministic record" do
    invocation = invocation("concurrent", :publishing)
    test_pid = self()
    {:ok, barrier} = Agent.start_link(fn -> 0 end)

    get_hook = fn ->
      visit = Agent.get_and_update(barrier, fn count -> {count + 1, count + 1} end)

      if visit == 1 do
        send(test_pid, {:get_waiting, self()})

        receive do
          :release_get -> :ok
        end
      end
    end

    remote = configure_remote(get_hook: get_hook)

    tasks = for attempt <- [1, 2], do: Task.async(fn -> perform(invocation, attempt) end)

    assert_receive {:get_waiting, first}
    refute_receive {:get_waiting, _duplicate}, 100
    send(first, :release_get)

    assert Task.await_many(tasks) == [:ok, :ok]
    assert Repo.reload!(invocation).stage == :complete
    assert visible_count(remote) == 1

    snapshot = Remote.snapshot(remote)
    assert snapshot.visible["value"] == invocation.reply_record
    assert Enum.count(snapshot.calls, &match?({:put, _, _, _, _}, &1)) == 1
  end

  test "publishes both parts sequentially for a split reply with part2 rebuilt using part1's published CID" do
    rkey_part1 = "3mreplypart1111"
    rkey_part2 = "3mreplypart2222"
    part1_cid = "bafy-part1-published"
    part2_cid = "bafy-part2-published"
    invocation_uri = "at://did:plc:actor/app.bsky.feed.post/split"

    invocation =
      invocation("split", :reply_ready, %{
        reply_rkey: rkey_part1,
        reply_part2_rkey: rkey_part2,
        reply_part2_record: %{
          "$type" => "app.bsky.feed.post",
          "text" => "This is part 2 of the split reply.",
          "createdAt" => "2026-07-29T12:59:01.123456Z",
          "reply" => %{
            "parent" => %{
              "uri" => "at://#{@bot_did}/#{@collection}/#{rkey_part1}"
            },
            "root" => %{
              "uri" => invocation_uri,
              "cid" => "bafy-current-split"
            }
          }
        }
      })

    part1_remote_record = remote_record(invocation, part1_cid)
    part1_uri = part1_remote_record["uri"]

    rebuilt_part2_record = %{
      "$type" => "app.bsky.feed.post",
      "text" => "This is part 2 of the split reply.",
      "createdAt" => "2026-07-29T12:59:01.123456Z",
      "reply" => %{
        "parent" => %{
          "uri" => part1_uri,
          "cid" => part1_cid
        },
        "root" => %{
          "uri" => part1_uri,
          "cid" => part1_cid
        }
      }
    }

    part2_remote_record = %{
      "uri" => "at://#{@bot_did}/#{@collection}/#{rkey_part2}",
      "cid" => part2_cid,
      "value" => rebuilt_part2_record
    }

    remote =
      configure_remote(
        get_results: [
          {:error, :record_not_found},
          {:ok, 200, %{}, part1_remote_record},
          {:error, :record_not_found},
          {:ok, 200, %{}, part2_remote_record}
        ],
        put_results: [
          {:ok, 200, %{}, %{"uri" => part1_uri, "cid" => part1_cid}},
          {:ok, 200, %{}, %{"uri" => part2_remote_record["uri"], "cid" => part2_cid}}
        ]
      )

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.status == :complete
    assert persisted.reply_uri == part1_uri
    assert persisted.reply_cid == part1_cid
    assert persisted.reply_part2_uri == part2_remote_record["uri"]
    assert persisted.reply_part2_cid == part2_cid
    assert persisted.completed_at == @now

    snapshot = Remote.snapshot(remote)

    assert Enum.member?(snapshot.calls, {:get, @bot_did, @collection, rkey_part1})

    assert Enum.member?(
             snapshot.calls,
             {:put, @bot_did, @collection, rkey_part1, invocation.reply_record}
           )

    assert Enum.member?(snapshot.calls, {:get, @bot_did, @collection, rkey_part2})

    assert Enum.member?(
             snapshot.calls,
             {:put, @bot_did, @collection, rkey_part2, rebuilt_part2_record}
           )

    assert length(snapshot.calls) == 6
  end

  defp configure_remote(options \\ []) do
    get_hook = Keyword.get(options, :get_hook)
    put_hook = Keyword.get(options, :put_hook)
    options = Keyword.drop(options, [:get_hook, :put_hook])
    {:ok, remote} = Remote.start_link(options)

    Application.put_env(:context_bot, PDS,
      remote: remote,
      get_hook: get_hook,
      put_hook: put_hook
    )

    configure_worker()

    remote
  end

  defp configure_worker(overrides \\ []) do
    defaults = [
      claim_lease_ms: 300_000,
      client: PDS,
      now: fn -> @now end,
      settings: Settings.load(bot_did: @bot_did)
    ]

    Application.put_env(:context_bot, ReplyWorker, Keyword.merge(defaults, overrides))
  end

  defp perform(invocation, attempt \\ 1, job_id \\ nil) do
    ReplyWorker.perform(%Oban.Job{
      id: job_id,
      attempt: attempt,
      max_attempts: 10,
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
    })
  end

  defp rate_limited_job(retry_after) do
    %Oban.Job{
      attempt: 1,
      max_attempts: 10,
      unsaved_error: %{
        kind: :error,
        reason: %Oban.PerformError{reason: {:error, {:rate_limited, retry_after}}},
        stacktrace: []
      }
    }
  end

  defp invocation(suffix, stage \\ :reply_ready, overrides \\ %{}) do
    uri = "at://did:plc:actor/app.bsky.feed.post/#{suffix}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: "bafy-#{suffix}",
          current_cid: "bafy-current-#{suffix}",
          actor_did: "did:plc:actor",
          raw_notification: %{"uri" => uri, "cid" => "bafy-#{suffix}"},
          received_at: DateTime.add(@now, -60),
          status: stage,
          stage: stage,
          selected_reply: "Frozen context for #{suffix}.",
          reply_repo: @bot_did,
          reply_rkey: @rkey,
          reply_record: %{
            "$type" => "app.bsky.feed.post",
            "text" => "Frozen context for #{suffix}.",
            "createdAt" => "2026-07-29T12:59:00.123456Z",
            "reply" => %{
              "parent" => %{"uri" => uri, "cid" => "bafy-current-#{suffix}"},
              "root" => %{"uri" => uri, "cid" => "bafy-current-#{suffix}"}
            }
          }
        },
        overrides
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp remote_record(invocation, cid) do
    %{
      "uri" => "at://#{@bot_did}/#{@collection}/#{invocation.reply_rkey}",
      "cid" => cid,
      "value" => invocation.reply_record
    }
  end

  defp visible_count(remote) do
    case Remote.snapshot(remote).visible do
      nil -> 0
      _record -> 1
    end
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
