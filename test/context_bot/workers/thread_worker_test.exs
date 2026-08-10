defmodule ContextBot.Workers.ThreadWorkerTest.Client do
  @moduledoc false

  def get_post_thread(uri, parent_height) do
    config = Application.fetch_env!(:context_bot, __MODULE__)

    send(
      config[:test_pid],
      {:thread_fetch, uri, parent_height, ContextBot.Repo.in_transaction?()}
    )

    if delay_ms = config[:delay_ms], do: Process.sleep(delay_ms)

    case config[:result] do
      result_function when is_function(result_function, 0) -> result_function.()
      result -> result
    end
  end
end

defmodule ContextBot.Workers.ThreadWorkerTest.PublicClient do
  @moduledoc false

  def get_post_thread(uri, parent_height) do
    config = Application.fetch_env!(:context_bot, ContextBot.Workers.ThreadWorkerTest.Client)

    send(
      config[:test_pid],
      {:public_thread_fetch, uri, parent_height, ContextBot.Repo.in_transaction?()}
    )

    config[:result]
  end
end

defmodule ContextBot.Workers.ThreadWorkerTest.AuthenticatedClient do
  @moduledoc false

  def get_post_thread(uri, parent_height) do
    config = Application.fetch_env!(:context_bot, ContextBot.Workers.ThreadWorkerTest.Client)
    send(config[:test_pid], {:authenticated_thread_fetch, uri, parent_height})
    config[:result]
  end
end

defmodule ContextBot.Workers.ThreadWorkerTest.SessionStub do
  @moduledoc false

  def access_token, do: {:ok, "worker-test-access-token"}
  def refresh(_rejected_token), do: {:error, :unexpected_refresh}
end

defmodule ContextBot.Workers.ThreadWorkerTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.ATProto.ReqClient
  alias ContextBot.Settings
  alias ContextBot.Workers.ThreadWorker

  alias ContextBot.Workers.ThreadWorkerTest.{
    AuthenticatedClient,
    Client,
    PublicClient,
    SessionStub
  }

  alias ContextBot.Workflow.Invocation

  @bot_did "did:plc:contextbot"
  @invocation_uri "at://did:plc:alice/app.bsky.feed.post/invocation"
  @notification_cid "bafy-invocation-v1"
  @now ~U[2026-07-29 12:00:00.123456Z]

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_worker_config = Application.get_env(:context_bot, ThreadWorker, :missing)
    original_client_config = Application.get_env(:context_bot, Client, :missing)
    original_req_config = Application.fetch_env!(:context_bot, ReqClient)

    on_exit(fn ->
      restore_env(ThreadWorker, original_worker_config)
      restore_env(Client, original_client_config)
      Application.put_env(:context_bot, ReqClient, original_req_config)
    end)

    :ok
  end

  test "requests depth zero through the authenticated client and atomically hands frozen thread state to research" do
    invocation = invocation()
    response = fixture("thread_ancestors.json")
    configure(settings(thread_parent_height: 2), client: ReqClient)

    Application.put_env(
      :context_bot,
      ReqClient,
      Application.fetch_env!(:context_bot, ReqClient)
      |> Keyword.put(:session, SessionStub)
      |> Keyword.update!(:req_options, &Keyword.put(&1, :plugins, []))
    )

    Req.Test.expect(ReqClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/xrpc/app.bsky.feed.getPostThread"

      assert conn.query_string
             |> URI.query_decoder()
             |> Enum.to_list()
             |> Enum.sort() ==
               Enum.sort([
                 {"depth", "0"},
                 {"parentHeight", "2"},
                 {"uri", @invocation_uri}
               ])

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer worker-test-access-token"
             ]

      Req.Test.json(conn, response)
    end)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :thread_ready
    assert persisted.stage == :thread_ready
    assert persisted.raw_thread == response
    assert persisted.canonical_thread_version == "1"
    assert persisted.canonical_thread =~ "The root claim."
    assert persisted.canonical_thread =~ "@contextbot.test please add context."
    refute persisted.canonical_thread =~ "DESCENDANT"
    assert persisted.root_uri == "at://did:plc:root/app.bsky.feed.post/root"
    assert persisted.root_cid == "bafy-root"
    assert persisted.current_cid == "bafy-invocation-v1"

    assert [%Oban.Job{} = research_job] = Repo.all(Oban.Job)
    assert research_job.worker == "ContextBot.Workers.ResearchWorker"
    assert research_job.queue == "research"

    assert research_job.args == %{
             "uri" => @invocation_uri,
             "cid" => @notification_cid
           }

    assert research_job.state == "available"

    # A future research worker can only observe this durable snapshot after its job is visible.
    assert Repo.get!(Invocation, invocation.id).stage == :thread_ready
  end

  test "routes a dry run through the public target and stores its local question for research" do
    invocation = dry_run_invocation()

    response =
      fixture("thread_ancestors.json")
      |> update_in(["thread", "post", "record"], &Map.delete(&1, "facets"))

    Application.put_env(:context_bot, Client, test_pid: self(), result: {:ok, 200, %{}, response})

    configure(settings(),
      client: AuthenticatedClient,
      public_client: PublicClient
    )

    assert :ok = perform(invocation)

    assert_received {:public_thread_fetch, @invocation_uri, 80, false}
    refute_receive {:authenticated_thread_fetch, _, _}

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :thread_ready
    assert persisted.current_cid == @notification_cid
    assert persisted.canonical_thread =~ "[target]\n"
    assert persisted.canonical_thread =~ "@contextbot.test please add context."
    assert persisted.canonical_thread =~ "[invocation]\nText:\nIs this fair?"
    refute persisted.canonical_thread =~ "DESCENDANT"

    assert [%Oban.Job{} = research_job] = Repo.all(Oban.Job)
    assert research_job.queue == "dry_research"

    assert research_job.args == %{
             "uri" => invocation.invocation_uri,
             "cid" => invocation.notification_cid
           }
  end

  test "fetches outside transactions, freezes an edited current CID, and ignores a completed handoff" do
    invocation = invocation()
    response = fixture("thread_edited_cid.json")
    configure_fake({:ok, 200, %{}, response})

    assert :ok = perform(invocation)

    assert_received {:thread_fetch, @invocation_uri, 80, false}
    persisted = Repo.reload!(invocation)
    assert persisted.current_cid == "bafy-invocation-v2"
    assert persisted.root_uri == @invocation_uri
    assert persisted.root_cid == "bafy-invocation-v2"

    assert :ok = perform(persisted)
    refute_receive {:thread_fetch, _, _, _}
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "logs a thread attempt without thread or identity content" do
    invocation = invocation()
    configure_fake({:ok, 200, %{}, fixture("thread_ancestors.json")})
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    assert log =~ "\"invocation_id\":#{invocation.id}"
    assert log =~ "\"stage\":\"capturing_thread\""
    assert log =~ "\"attempt_kind\":\"thread\""
    refute log =~ invocation.invocation_uri
    refute log =~ "The root claim"
  end

  test "rolls back both the thread snapshot and research job when the handoff transaction fails" do
    invocation = invocation()
    response = fixture("thread_ancestors.json")

    invalid_job_builder = fn transitioned_invocation ->
      %{
        "uri" => transitioned_invocation.invocation_uri,
        "cid" => transitioned_invocation.notification_cid
      }
      |> Oban.Job.new(worker: "ContextBot.Workers.ResearchWorker", queue: :research)
      |> Ecto.Changeset.add_error(:args, "forced handoff failure")
    end

    configure_fake({:ok, 200, %{}, response}, research_job_builder: invalid_job_builder)

    assert_raise Ecto.InvalidChangesetError, fn -> perform(invocation) end
    assert_received {:thread_fetch, @invocation_uri, 80, false}

    persisted = Repo.reload!(invocation)
    assert persisted.status == :capturing_thread
    assert persisted.stage == :capturing_thread
    assert persisted.raw_thread == nil
    assert persisted.canonical_thread == nil
    assert persisted.canonical_thread_version == nil
    assert persisted.root_uri == nil
    assert persisted.root_cid == nil
    assert persisted.current_cid == @notification_cid
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "records an oversized raw snapshot as a finite terminal failure" do
    invocation = invocation()
    response = fixture("thread_ancestors.json")

    configure_fake(
      {:ok, 200, %{}, response},
      settings: settings(max_response_bytes: 128, max_storage_bytes: 1_000_000)
    )

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :failed
    assert persisted.stage == :failed
    assert persisted.failure_category == :thread_unavailable
    assert persisted.failure_detail == %{"reason" => "response_too_large"}
    assert persisted.raw_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "records a transport-level response overflow as a finite terminal failure" do
    invocation = invocation()
    configure_fake({:error, :response_too_large})

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_detail == %{"reason" => "response_too_large"}
    assert persisted.raw_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "bounds a slow fetch before any response can be persisted" do
    invocation = invocation()
    response = fixture("thread_ancestors.json")

    Application.put_env(:context_bot, Client,
      test_pid: self(),
      result: {:ok, 200, %{}, response},
      delay_ms: 100
    )

    configure(settings(thread_fetch_timeout_ms: 10), client: Client)

    assert {:error, :timeout} = perform(invocation)
    assert_received {:thread_fetch, @invocation_uri, 80, false}
    assert Repo.reload!(invocation).raw_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "returns transient fetch failures for retry with capped backoff" do
    invocation = invocation()
    configure_fake({:error, :timeout})

    assert {:error, :timeout} = perform(invocation)
    assert Repo.reload!(invocation).stage == :capturing_thread
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert ThreadWorker.backoff(%Oban.Job{attempt: 1, max_attempts: 10}) == 15
    assert ThreadWorker.backoff(%Oban.Job{attempt: 5, max_attempts: 10}) == 240
    assert ThreadWorker.backoff(%Oban.Job{attempt: 10, max_attempts: 10}) == 300
  end

  test "makes a transient fetch failure finite on the final Oban attempt" do
    invocation = invocation()
    configure_fake({:error, :timeout})

    assert :ok = perform(invocation, 10)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :failed
    assert persisted.stage == :failed
    assert persisted.failure_category == :thread_unavailable
    assert persisted.failure_detail == %{"reason" => "retry_exhausted"}
    assert persisted.completed_at
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "silently records permanent target unavailability and publishes no downstream work" do
    invocation = invocation()
    configure_fake({:error, :record_not_found})

    assert :ok = perform(invocation)

    failed = Repo.reload!(invocation)
    assert failed.status == :failed
    assert failed.stage == :failed
    assert failed.failure_category == :thread_unavailable
    assert failed.failure_detail == %{"reason" => "target_unavailable"}
    assert failed.completed_at
    assert failed.raw_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "treats an unavailable target union as terminal without a research handoff" do
    invocation = invocation()

    target = %{
      "thread" => %{
        "$type" => "app.bsky.feed.defs#notFoundPost",
        "uri" => @invocation_uri,
        "notFound" => true
      }
    }

    configure_fake({:ok, 200, %{}, target})

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).failure_category == :thread_unavailable
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "silently records an invalid fetched thread as terminal without a research handoff" do
    invocation = invocation()

    invalid_thread =
      put_in(
        fixture("thread_ancestors.json"),
        ["thread", "post", "record", "reply"],
        "not-a-map"
      )

    configure_fake({:ok, 200, %{}, invalid_thread})

    assert :ok = perform(invocation)

    failed = Repo.reload!(invocation)
    assert failed.status == :failed
    assert failed.stage == :failed
    assert failed.failure_category == :thread_unavailable
    assert failed.failure_detail == %{"reason" => "invalid_thread"}
    assert failed.raw_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "silently records a non-map successful thread body as terminal" do
    invocation = invocation()
    configure_fake({:ok, 200, %{}, "not-a-thread-object"})

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).failure_detail == %{"reason" => "invalid_thread"}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a stale permanent fetch cannot overwrite a concurrent successful handoff" do
    invocation = invocation()
    test_pid = self()

    stale_result = fn ->
      send(test_pid, {:stale_fetch_waiting, self()})

      receive do
        :release_stale_fetch -> {:error, :record_not_found}
      after
        5_000 -> {:error, :timeout}
      end
    end

    configure_fake(stale_result)
    stale_worker = Task.async(fn -> perform(invocation) end)
    assert_receive {:stale_fetch_waiting, stale_fetch_pid}

    response = fixture("thread_ancestors.json")
    configure_fake({:ok, 200, %{}, response})
    assert :ok = perform(invocation)

    send(stale_fetch_pid, :release_stale_fetch)
    assert :ok = Task.await(stale_worker)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :thread_ready
    assert persisted.stage == :thread_ready
    assert persisted.raw_thread == response
    assert persisted.failure_category == nil
    assert persisted.failure_detail == nil

    assert [%Oban.Job{worker: "ContextBot.Workers.ResearchWorker", queue: "research"}] =
             Repo.all(Oban.Job)
  end

  defp configure_fake(result, overrides \\ []) do
    Application.put_env(:context_bot, Client, test_pid: self(), result: result)

    configure(
      Keyword.get(overrides, :settings, settings()),
      Keyword.put(overrides, :client, Client)
    )
  end

  defp configure(settings, overrides) do
    Application.put_env(
      :context_bot,
      ThreadWorker,
      Keyword.merge([settings: settings], overrides)
    )
  end

  defp settings(overrides \\ []),
    do: Settings.load(Keyword.merge([bot_did: @bot_did], overrides))

  defp perform(invocation, attempt \\ 1) do
    ThreadWorker.perform(%Oban.Job{
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      attempt: attempt,
      max_attempts: 10
    })
  end

  defp invocation do
    %Invocation{}
    |> Invocation.changeset(%{
      invocation_uri: @invocation_uri,
      notification_cid: @notification_cid,
      current_cid: @notification_cid,
      actor_did: "did:plc:alice",
      actor_handle: "alice.test",
      raw_notification: %{"uri" => @invocation_uri, "cid" => @notification_cid},
      received_at: @now,
      admitted_at: @now,
      status: :capturing_thread,
      stage: :capturing_thread
    })
    |> Repo.insert!()
  end

  defp dry_run_invocation do
    run_id = Ecto.UUID.generate()

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: true,
      target_uri: @invocation_uri,
      invocation_text: "Is this fair?",
      invocation_uri: "local://context-bot/dry-runs/#{run_id}",
      notification_cid: "local:#{run_id}",
      current_cid: "local:#{run_id}",
      actor_did: "local:operator",
      raw_notification: %{"source" => "local_dry_run"},
      received_at: @now,
      status: :capturing_thread,
      stage: :capturing_thread
    })
    |> Repo.insert!()
  end

  defp fixture(name) do
    "test/fixtures/atproto/#{name}"
    |> File.read!()
    |> Jason.decode!()
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, config), do: Application.put_env(:context_bot, module, config)
end
