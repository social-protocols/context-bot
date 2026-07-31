defmodule ContextBot.Workers.ReplyWorkerTest.PDS do
  @moduledoc false

  alias ContextBot.Workers.ReplyWorkerTest.Remote

  def get_record(repo, collection, rkey) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    maybe_run_hook(config[:get_hook])
    Remote.get(config[:remote], repo, collection, rkey)
  end

  def put_record(repo, collection, rkey, record) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Remote.put(config[:remote], repo, collection, rkey, record)
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

  alias ContextBot.Settings
  alias ContextBot.Workers.ReplyWorker
  alias ContextBot.Workers.ReplyWorkerTest.{PDS, Remote}
  alias ContextBot.Workflow.Invocation

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

    assert {:error, :timeout} = perform(invocation, 1)
    retryable = Repo.reload!(invocation)
    assert retryable.stage == :publishing
    assert retryable.reply_rkey == @rkey
    assert retryable.reply_record == invocation.reply_record

    assert :ok = perform(invocation, 2)
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

      if visit <= 2 do
        send(test_pid, {:get_waiting, self()})

        receive do
          :release_get -> :ok
        end
      end
    end

    remote = configure_remote(get_hook: get_hook)

    tasks = for attempt <- [1, 2], do: Task.async(fn -> perform(invocation, attempt) end)

    assert_receive {:get_waiting, first}
    assert_receive {:get_waiting, second}
    send(first, :release_get)
    send(second, :release_get)

    assert Task.await_many(tasks) == [:ok, :ok]
    assert Repo.reload!(invocation).stage == :complete
    assert visible_count(remote) == 1

    snapshot = Remote.snapshot(remote)
    assert snapshot.visible["value"] == invocation.reply_record
    assert Enum.count(snapshot.calls, &match?({:put, _, _, _, _}, &1)) == 2
  end

  defp configure_remote(options \\ []) do
    get_hook = Keyword.get(options, :get_hook)
    options = Keyword.delete(options, :get_hook)
    {:ok, remote} = Remote.start_link(options)
    Application.put_env(:context_bot, PDS, remote: remote, get_hook: get_hook)

    settings = Settings.load(bot_did: @bot_did)

    Application.put_env(:context_bot, ReplyWorker,
      client: PDS,
      now: fn -> @now end,
      settings: settings
    )

    remote
  end

  defp perform(invocation, attempt \\ 1) do
    ReplyWorker.perform(%Oban.Job{
      attempt: attempt,
      max_attempts: 10,
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
    })
  end

  defp invocation(suffix, stage \\ :reply_ready) do
    uri = "at://did:plc:actor/app.bsky.feed.post/#{suffix}"

    attrs = %{
      invocation_uri: uri,
      notification_cid: "bafy-#{suffix}",
      current_cid: "bafy-current-#{suffix}",
      actor_did: "did:plc:actor",
      raw_notification: %{"uri" => uri, "cid" => "bafy-#{suffix}"},
      received_at: DateTime.add(@now, -60),
      status: stage,
      stage: stage,
      selected_reply: "Frozen context for #{suffix}.",
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
    }

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
