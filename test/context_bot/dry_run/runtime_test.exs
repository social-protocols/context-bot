defmodule ContextBot.DryRun.RuntimeTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.DryRun.Runtime
  alias ContextBot.Settings

  @now ~U[2026-08-10 18:00:00.000000Z]

  defmodule FakeRecovery do
    def recover_orphans(options) do
      %{result: result, test_pid: test_pid} =
        Application.fetch_env!(:context_bot, __MODULE__)

      send(test_pid, {
        :dry_runtime_recovery,
        options,
        Process.whereis(ContextBot.Repo),
        Oban.whereis(Oban)
      })

      result
    end
  end

  defmodule FakeDeferred do
    def reconsider_due(options) do
      %{result: result, test_pid: test_pid} =
        Application.fetch_env!(:context_bot, __MODULE__)

      send(test_pid, {:dry_runtime_deferred, options, Oban.whereis(Oban)})

      result
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:context_bot, FakeRecovery)
      Application.delete_env(:context_bot, FakeDeferred)
    end)

    :ok
  end

  test "base phase starts the application without starting Oban" do
    on_exit(&stop_oban/0)

    assert Oban.whereis(Oban) == nil
    assert :ok = Runtime.ensure_application_started()
    assert is_pid(Process.whereis(ContextBot.Repo))
    assert Oban.whereis(Oban) == nil
  end

  test "base phase rejects bot-enabled settings before starting any worker runtime" do
    original = Application.fetch_env!(:context_bot, :settings)
    Application.put_env(:context_bot, :settings, %{original | bot_enabled: true})
    on_exit(fn -> Application.put_env(:context_bot, :settings, original) end)

    assert {:error, :bot_enabled} = Runtime.ensure_application_started()
    assert Oban.whereis(Oban) == nil
  end

  test "base phase rejects a standalone registered public session" do
    assert Process.whereis(ContextBot.ATProto.Session) == nil
    on_exit(&stop_oban/0)
    session = start_supervised!({Agent, fn -> nil end}, id: :session_placeholder)
    Process.register(session, ContextBot.ATProto.Session)

    assert {:error, :public_worker_running} = Runtime.ensure_application_started()
    assert Oban.whereis(Oban) == nil
  end

  test "base phase rejects every pre-existing Oban runtime" do
    assert {:ok, _pid} = start_minimal_oban()
    on_exit(&stop_oban/0)

    assert {:error, :unsafe_oban_runtime} = Runtime.ensure_application_started()
  end

  test "workers recover then reconcile before starting serial dry queues" do
    configure_recovery({:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}})
    configure_deferred(:ok)
    on_exit(&stop_oban/0)

    assert :ok =
             Runtime.start_workers(
               recovery: FakeRecovery,
               deferred: FakeDeferred,
               now: fn -> @now end
             )

    assert_receive {:dry_runtime_recovery, [startup?: true, now: @now], repo_pid, nil}
    assert is_pid(repo_pid)

    assert_receive {:dry_runtime_deferred, [workflow: :dry_run, now: @now, settings: _settings],
                    nil}

    assert Oban.whereis(Oban)
    assert Oban.Registry.whereis(Oban, {:producer, "dry_thread"})
    assert Oban.Registry.whereis(Oban, {:producer, "dry_research"})
  end

  test "workers fail closed when the selected base application is no longer ready" do
    configure_recovery({:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}})
    configure_deferred(:ok)
    on_exit(&stop_oban/0)

    assert {:error, :application_not_started} =
             Runtime.start_workers(
               recovery: FakeRecovery,
               deferred: FakeDeferred,
               base_ready: fn -> {:error, :application_not_started} end
             )

    refute_received {:dry_runtime_recovery, _, _, _}
    refute_received {:dry_runtime_deferred, _, _}
    assert Oban.whereis(Oban) == nil
  end

  test "a recovery failure leaves standalone Oban stopped" do
    configure_recovery({:error, :recovery_failed})
    configure_deferred(:ok)

    assert {:error, :startup_recovery_failed} =
             Runtime.start_workers(
               recovery: FakeRecovery,
               deferred: FakeDeferred,
               now: fn -> @now end
             )

    assert_receive {:dry_runtime_recovery, [startup?: true, now: @now], repo_pid, nil}
    assert is_pid(repo_pid)
    refute_received {:dry_runtime_deferred, _, _}
    assert Oban.whereis(Oban) == nil
  end

  test "a deferred reconciliation failure leaves standalone Oban stopped" do
    configure_recovery({:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}})
    configure_deferred({:error, :deferred_reconciliation_failed})

    assert {:error, :deferred_reconciliation_failed} =
             Runtime.start_workers(
               recovery: FakeRecovery,
               deferred: FakeDeferred,
               now: fn -> @now end
             )

    assert_receive {:dry_runtime_recovery, [startup?: true, now: @now], _repo_pid, nil}

    assert_receive {:dry_runtime_deferred, [workflow: :dry_run, now: @now, settings: _settings],
                    nil}

    assert Oban.whereis(Oban) == nil
  end

  test "starts only the dedicated serial dry-run queues" do
    assert :ok = Runtime.start_workers()
    oban_pid = Oban.whereis(Oban)
    Process.unlink(oban_pid)
    on_exit(fn -> if Process.alive?(oban_pid), do: Process.exit(oban_pid, :shutdown) end)

    config = Oban.config(Oban)
    assert config.testing == :disabled
    assert config.plugins == []
    assert Enum.sort(Keyword.keys(config.queues)) == [:dry_research, :dry_thread]
    assert Enum.all?(config.queues, fn {_queue, options} -> options[:limit] == 1 end)
    assert Oban.Registry.whereis(Oban, {:producer, "dry_thread"})
    assert Oban.Registry.whereis(Oban, {:producer, "dry_research"})
    refute Oban.Registry.whereis(Oban, {:producer, "thread"})
    refute Oban.Registry.whereis(Oban, {:producer, "research"})
    refute Oban.Registry.whereis(Oban, {:producer, "reply"})

    assert :ok = Runtime.stop()
    refute Process.alive?(oban_pid)
    assert :ok = Runtime.stop()
  end

  test "accepts only the exact serial thread and research Oban configuration" do
    base = %Oban.Config{
      testing: :disabled,
      plugins: [],
      queues: [dry_thread: [limit: 1], dry_research: [limit: 1]]
    }

    assert Runtime.safe_oban_config?(base)

    refute Runtime.safe_oban_config?(%{
             base
             | queues: [dry_thread: [limit: 2], dry_research: [limit: 1]]
           })

    refute Runtime.safe_oban_config?(%{
             base
             | queues: [dry_thread: [limit: 1], dry_research: [limit: 1], reply: [limit: 1]]
           })

    refute Runtime.safe_oban_config?(base, ["dry_thread", "dry_research", "reply"])
    refute Runtime.safe_oban_config?(%{base | plugins: [Oban.Plugins.Cron]})
    refute Runtime.safe_oban_config?(%{base | testing: :manual})
  end

  test "does not mistake structurally valid disabled settings for enabled operation" do
    refute Settings.bot_enabled?(Settings.load([]))
  end

  defp stop_oban do
    if pid = Oban.whereis(Oban), do: Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp configure_recovery(result) do
    Application.put_env(:context_bot, FakeRecovery, %{result: result, test_pid: self()})
  end

  defp configure_deferred(result) do
    Application.put_env(:context_bot, FakeDeferred, %{result: result, test_pid: self()})
  end

  defp start_minimal_oban do
    options =
      :context_bot
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:queues, dry_thread: 1, dry_research: 1)
      |> Keyword.put(:plugins, [])
      |> Keyword.delete(:testing)

    Oban.start_link(options)
  end
end
