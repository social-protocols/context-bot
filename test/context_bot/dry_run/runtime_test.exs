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

  setup do
    on_exit(fn -> Application.delete_env(:context_bot, FakeRecovery) end)
    :ok
  end

  test "recovers after Repo starts and before either dry producer starts" do
    configure_recovery({:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}})
    on_exit(&stop_oban/0)

    assert :ok = Runtime.ensure_started(recovery: FakeRecovery, now: fn -> @now end)

    assert_receive {:dry_runtime_recovery, [startup?: true, now: @now], repo_pid, nil}
    assert is_pid(repo_pid)
    assert Oban.Registry.whereis(Oban, {:producer, "dry_thread"})
    assert Oban.Registry.whereis(Oban, {:producer, "dry_research"})
  end

  test "a recovery failure leaves standalone Oban stopped" do
    configure_recovery({:error, :recovery_failed})

    assert {:error, :startup_recovery_failed} =
             Runtime.ensure_started(recovery: FakeRecovery, now: fn -> @now end)

    assert_receive {:dry_runtime_recovery, [startup?: true, now: @now], repo_pid, nil}
    assert is_pid(repo_pid)
    assert Oban.whereis(Oban) == nil
  end

  test "rejects bot-enabled settings before starting any worker runtime" do
    original = Application.fetch_env!(:context_bot, :settings)
    Application.put_env(:context_bot, :settings, %{original | bot_enabled: true})
    on_exit(fn -> Application.put_env(:context_bot, :settings, original) end)

    assert {:error, :bot_enabled} = Runtime.ensure_started()
  end

  test "rejects a standalone registered public session before starting Oban" do
    assert Process.whereis(ContextBot.ATProto.Session) == nil
    on_exit(&stop_oban/0)
    session = start_supervised!({Agent, fn -> nil end}, id: :session_placeholder)
    Process.register(session, ContextBot.ATProto.Session)

    assert {:error, :public_worker_running} = Runtime.ensure_started()
    assert Oban.whereis(Oban) == nil
  end

  test "starts and safely reuses only the dedicated serial dry-run queues" do
    assert Oban.whereis(Oban) == nil

    assert :ok = Runtime.ensure_started()
    oban_pid = Oban.whereis(Oban)
    Process.unlink(oban_pid)
    on_exit(fn -> if Process.alive?(oban_pid), do: Process.exit(oban_pid, :shutdown) end)

    assert :ok = Runtime.ensure_started()

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
end
