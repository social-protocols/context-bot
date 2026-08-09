defmodule ContextBot.DryRun.RuntimeTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.DryRun.Runtime
  alias ContextBot.Settings

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

    assert :ok = Supervisor.stop(oban_pid)
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
end
