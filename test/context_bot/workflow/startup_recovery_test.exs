defmodule ContextBot.Workflow.StartupRecoveryTest do
  use ExUnit.Case, async: false

  alias ContextBot.Workflow.StartupRecovery

  @now ~U[2026-08-10 18:00:00.000000Z]

  defmodule FakeRecovery do
    def recover_orphans(options) do
      %{test_pid: test_pid, result: result, wait?: wait?} =
        Application.fetch_env!(:context_bot, __MODULE__)

      send(test_pid, {:recover, self(), options})
      if wait?, do: receive(do: (:continue -> :ok))
      result
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:context_bot, FakeRecovery) end)
    :ok
  end

  test "blocks startup until recovery succeeds, then remains idle" do
    summary = %{examined: 2, resumed: 1, terminalized: 0, unchanged: 1}
    configure_fake({:ok, summary}, true)

    task =
      Task.async(fn ->
        StartupRecovery.start_link(recovery: FakeRecovery, now: fn -> @now end)
      end)

    assert_receive {:recover, recovery_pid, options}
    assert options == [startup?: true, now: @now]
    assert Task.yield(task, 0) == nil

    send(recovery_pid, :continue)
    assert {:ok, pid} = Task.await(task)
    assert Process.alive?(pid)
    assert :sys.get_state(pid) == %{summary: summary}
    GenServer.stop(pid)
  end

  test "returns only a safe startup error when recovery fails" do
    configure_fake({:error, {:database_error, "private detail"}}, false)
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, :startup_recovery_failed} =
             StartupRecovery.start_link(recovery: FakeRecovery, now: fn -> @now end)

    assert_receive {:recover, _pid, startup?: true, now: @now}
  end

  defp configure_fake(result, wait?) do
    Application.put_env(:context_bot, FakeRecovery, %{
      test_pid: self(),
      result: result,
      wait?: wait?
    })
  end
end
