defmodule ContextBot.LiveRun.RuntimeTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.LiveRun.Runtime
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-08-11 23:00:00.000000Z]

  defmodule FakeOwner do
    def acquire(options) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:owner_acquire, options})
      config[:acquire_result]
    end

    def owned?(owner) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:owner_checked, owner})
      config[:owned]
    end

    def release(owner) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:owner_released, owner})
      :ok
    end
  end

  defmodule FakeSession do
    def start_link(options) do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], {:session_started, options})
      Agent.start_link(fn -> :session end, name: options[:name])
    end

    def access_token do
      config = Application.fetch_env!(:context_bot, __MODULE__)
      send(config[:test_pid], :access_token_requested)
      config[:access_result]
    end
  end

  defmodule FakeRecovery do
    def recover_invocation(invocation, options) do
      test_pid = Application.fetch_env!(:context_bot, __MODULE__)[:test_pid]
      send(test_pid, {:recover_exactly, invocation.id, options})
      :unchanged
    end
  end

  setup do
    original_owner = Application.get_env(:context_bot, FakeOwner, :missing)
    original_session = Application.get_env(:context_bot, FakeSession, :missing)
    original_recovery = Application.get_env(:context_bot, FakeRecovery, :missing)

    Application.put_env(:context_bot, FakeOwner,
      test_pid: self(),
      acquire_result: {:ok, self()},
      owned: true
    )

    Application.put_env(:context_bot, FakeSession,
      test_pid: self(),
      access_result: {:ok, "access-token"}
    )

    Application.put_env(:context_bot, FakeRecovery, test_pid: self())

    on_exit(fn ->
      stop_oban()
      stop_session()
      restore_env(FakeOwner, original_owner)
      restore_env(FakeSession, original_session)
      restore_env(FakeRecovery, original_recovery)
    end)

    :ok
  end

  test "configures and starts the disabled application against an isolated migrated database" do
    root = temp_directory("configure")
    selected = Path.join(root, "nested/live-demo.db")
    configured = Path.join(root, "data/context_bot_dev.db")
    test_pid = self()

    assert {:ok, ^selected} =
             Runtime.configure_and_start(selected,
               project_root: root,
               configured_database: configured,
               bot_app_password: "app-password",
               settings: settings(),
               put_bot_password: fn value ->
                 send(test_pid, {:bot_password, value})
                 :ok
               end,
               configure_repo: fn path ->
                 send(test_pid, {:repo_configured, path})
                 :ok
               end,
               migrate: fn ->
                 send(test_pid, :migrated)
                 :ok
               end,
               application_start: fn ->
                 send(test_pid, :application_started)
                 :ok
               end,
               runtime_ready: fn ->
                 send(test_pid, :runtime_ready)
                 :ok
               end
             )

    assert File.dir?(Path.dirname(selected))
    assert_receive {:bot_password, "app-password"}
    assert_receive {:repo_configured, ^selected}
    assert_receive :migrated
    assert_receive :application_started
    assert_receive :runtime_ready
  end

  test "rejects unsafe database paths and invalid live settings before side effects" do
    root = temp_directory("unsafe")
    configured = Path.join(root, "data/context_bot_dev.db")
    production = Path.join(root, "production.db")
    test_pid = self()

    side_effect = fn value -> send(test_pid, {:unexpected_side_effect, value}) end

    for path <- [
          configured,
          Path.join(root, "data/context_bot_test.db"),
          Path.join(root, "data/context_bot_test_12.db"),
          production,
          ":memory:",
          ""
        ] do
      assert {:error, :unsafe_database_path} =
               Runtime.configure_and_start(path,
                 project_root: root,
                 configured_database: configured,
                 production_database: production,
                 bot_app_password: "app-password",
                 settings: settings(),
                 put_bot_password: side_effect,
                 configure_repo: side_effect,
                 migrate: fn -> send(test_pid, {:unexpected_side_effect, :migrate}) end,
                 application_start: fn -> send(test_pid, {:unexpected_side_effect, :start}) end
               )
    end

    assert {:error, :bot_enabled} =
             Runtime.configure_and_start("data/live-demo.db",
               project_root: root,
               configured_database: configured,
               bot_app_password: "app-password",
               settings: %{settings() | bot_enabled: true}
             )

    assert {:error, :missing_configuration} =
             Runtime.configure_and_start("data/live-demo.db",
               project_root: root,
               configured_database: configured,
               bot_app_password: nil,
               settings: settings()
             )

    refute_received {:unexpected_side_effect, _value}
  end

  test "acquires the database-scoped owner and eagerly authenticates the configured bot" do
    database = "/tmp/context-bot-live-runtime-test.db"

    assert {:ok, owner} = Runtime.try_acquire_owner(database, owner: FakeOwner)
    assert_receive {:owner_acquire, [database: ^database]}

    assert :ok = Runtime.authenticate(owner, owner: FakeOwner, session: FakeSession)
    assert_receive {:owner_checked, ^owner}
    assert_receive {:session_started, [name: ContextBot.ATProto.Session]}
    assert_receive :access_token_requested
    assert Process.whereis(ContextBot.ATProto.Session)
  end

  test "authentication failure stops the temporary session and preserves ownership" do
    Application.put_env(:context_bot, FakeSession,
      test_pid: self(),
      access_result: {:error, :authentication_failed}
    )

    assert {:error, :session_unavailable} =
             Runtime.authenticate(self(), owner: FakeOwner, session: FakeSession)

    assert Process.whereis(ContextBot.ATProto.Session) == nil
    refute_received {:owner_released, _owner}
  end

  test "recovers only the selected invocation before starting serial public queues" do
    invocation = live_invocation!("selected", :capturing_thread)

    assert :ok =
             Runtime.start_workers(self(), invocation,
               owner: FakeOwner,
               recovery: FakeRecovery,
               now: fn -> @now end,
               base_ready: fn -> :ok end
             )

    assert_receive {:recover_exactly, id, [startup?: true, now: @now, settings: _settings]}
    assert id == invocation.id

    config = Oban.config(Oban)
    assert config.testing == :disabled
    assert config.plugins == []
    assert Enum.sort(Keyword.keys(config.queues)) == [:reply, :research, :thread]
    assert Enum.all?(config.queues, fn {_queue, options} -> options[:limit] == 1 end)
    refute Oban.Registry.whereis(Oban, {:producer, "eligibility"})
    refute Oban.Registry.whereis(Oban, {:producer, "maintenance"})
    refute Process.whereis(ContextBot.Mentions.Poller)
  end

  test "refuses to start queues while another invocation is nonterminal" do
    selected = live_invocation!("selected-active", :capturing_thread)
    other = live_invocation!("other-active", :researching)

    assert {:error, :active_invocation, %{id: id, uri: uri}} =
             Runtime.start_workers(self(), selected,
               owner: FakeOwner,
               recovery: FakeRecovery,
               base_ready: fn -> :ok end
             )

    assert id == other.id
    assert uri == other.invocation_uri
    refute_received {:recover_exactly, _, _}
    assert Oban.whereis(Oban) == nil
  end

  test "rejects a lost owner before recovery or queue startup" do
    invocation = live_invocation!("lost-owner", :capturing_thread)

    Application.put_env(:context_bot, FakeOwner,
      test_pid: self(),
      acquire_result: {:ok, self()},
      owned: false
    )

    assert {:error, :runtime_lock_lost} =
             Runtime.start_workers(self(), invocation,
               owner: FakeOwner,
               recovery: FakeRecovery,
               base_ready: fn -> :ok end
             )

    refute_received {:recover_exactly, _, _}
    assert Oban.whereis(Oban) == nil
  end

  test "stops owned queues and session before releasing the owner" do
    invocation = live_invocation!("stop", :capturing_thread)
    assert :ok = Runtime.authenticate(self(), owner: FakeOwner, session: FakeSession)

    assert :ok =
             Runtime.start_workers(self(), invocation,
               owner: FakeOwner,
               recovery: FakeRecovery,
               base_ready: fn -> :ok end
             )

    oban = Oban.whereis(Oban)
    session = Process.whereis(ContextBot.ATProto.Session)

    assert :ok = Runtime.stop(self(), owner: FakeOwner)
    refute Process.alive?(oban)
    refute Process.alive?(session)
    assert_receive {:owner_released, _owner}
  end

  test "accepts only the exact serial live queue configuration" do
    base = %Oban.Config{
      testing: :disabled,
      plugins: [],
      queues: [thread: [limit: 1], research: [limit: 1], reply: [limit: 1]]
    }

    assert Runtime.safe_oban_config?(base)
    refute Runtime.safe_oban_config?(%{base | plugins: [Oban.Plugins.Cron]})
    refute Runtime.safe_oban_config?(%{base | queues: [thread: [limit: 1]]})

    refute Runtime.safe_oban_config?(%{
             base
             | queues: [thread: [limit: 2], research: [limit: 1], reply: [limit: 1]]
           })
  end

  defp settings do
    Settings.load(
      bot_did: "did:plc:contextbot",
      bot_handle: "getcontext.bot",
      bot_pds_url: "https://pds.example",
      anthropic_daily_budget_usd: "20.000000"
    )
  end

  defp live_invocation!(suffix, stage) do
    uri = "at://did:plc:actor/app.bsky.feed.post/#{suffix}"

    receipt = %{
      uri: uri,
      cid: "bafy-#{suffix}",
      actor_did: "did:plc:actor",
      actor_handle: "actor.test",
      invocation_text: "Question?",
      raw: %{"source" => "local_live_demo", "post" => %{"uri" => uri}}
    }

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: false,
      invocation_uri: uri,
      notification_cid: receipt.cid,
      current_cid: receipt.cid,
      actor_did: receipt.actor_did,
      raw_notification: receipt.raw,
      received_at: @now,
      eligibility_method: "operator_live_demo",
      eligibility_evidence: %{"source" => "explicit_local_command"},
      admitted_at: @now,
      status: stage,
      stage: stage
    })
    |> Repo.insert!()
  end

  defp temp_directory(suffix) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "context-bot-live-runtime-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp stop_oban do
    if pid = Oban.whereis(Oban), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp stop_session do
    if pid = Process.whereis(ContextBot.ATProto.Session), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
