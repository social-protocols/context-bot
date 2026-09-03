defmodule Mix.Tasks.ContextBot.RecoverTest.Service do
  @moduledoc false

  def recover_orphans(options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:recover_orphans, options})
    config[:orphans_result]
  end

  def recover_invocation(invocation_or_id, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:recover_invocation, invocation_or_id, options})
    config[:invocation_result]
  end
end

defmodule Mix.Tasks.ContextBot.RecoverTest.Runtime do
  @moduledoc false

  def ensure_started do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], :application_started)
    config[:result]
  end
end

defmodule Mix.Tasks.ContextBot.RecoverTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ContextBot.Recover, as: RecoverTask
  alias Mix.Tasks.ContextBot.RecoverTest.{Runtime, Service}

  setup do
    original_shell = Mix.shell()
    original_task = Application.get_env(:context_bot, RecoverTask, :missing)
    original_service = Application.get_env(:context_bot, Service, :missing)
    original_runtime = Application.get_env(:context_bot, Runtime, :missing)

    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(:context_bot, RecoverTask,
      recovery: Service,
      runtime: Runtime,
      now: fn -> ~U[2026-09-03 01:30:00.000000Z] end
    )

    Application.put_env(:context_bot, Runtime, test_pid: self(), result: :ok)

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      orphans_result: {:ok, %{examined: 2, resumed: 1, terminalized: 0, unchanged: 1}},
      invocation_result: :resumed
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      restore_env(RecoverTask, original_task)
      restore_env(Service, original_service)
      restore_env(Runtime, original_runtime)
    end)

    :ok
  end

  test "loads configuration before starting the application" do
    assert RecoverTask.__info__(:attributes)[:requirements] == ["app.config"]
  end

  test "rejects extra or invalid invocation IDs before startup" do
    for arguments <- [["1", "2"], ["0"], ["-1"], ["nope"], ["1suffix"]] do
      assert_raise Mix.Error, ~r/positive integer invocation ID/, fn -> run(arguments) end
      refute_received :application_started
      refute_received {:recover_orphans, _}
      refute_received {:recover_invocation, _, _}
    end
  end

  test "with no arguments starts the application and prints the orphan summary" do
    assert :ok = run([])

    assert_received :application_started

    assert_received {:recover_orphans,
                     [
                       now: ~U[2026-09-03 01:30:00.000000Z],
                       job_states: ["executing", "completed", "cancelled", "discarded"]
                     ]}

    assert shell_output() ==
             "status=recovered\nexamined=2\nresumed=1\nterminalized=0\nunchanged=1\n"
  end

  test "treats an empty argument as a full recovery scan" do
    assert :ok = run([""])
    assert_received :application_started
    assert_received {:recover_orphans, _options}
    refute_received {:recover_invocation, _, _}
  end

  test "with one id recovers that invocation and prints only the identity" do
    assert :ok = run(["22"])

    assert_received :application_started
    assert_received {:recover_invocation, 22, [now: ~U[2026-09-03 01:30:00.000000Z]]}
    assert shell_output() == "status=resumed\ninvocation_id=22\n"
  end

  test "maps a missing invocation without exposing internals" do
    Application.put_env(:context_bot, Service,
      test_pid: self(),
      orphans_result: {:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}},
      invocation_result: {:error, :not_found}
    )

    error = assert_raise Mix.Error, fn -> run(["22"]) end
    assert error.message =~ "invocation not found"
  end

  test "maps recovery and startup failures without exposing their details" do
    sentinel = "sentinel-private-provider-body"

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      orphans_result: {:error, {:unexpected, sentinel}},
      invocation_result: :resumed
    )

    error = assert_raise Mix.Error, fn -> run([]) end
    assert error.message =~ "recovery failed"
    refute error.message =~ sentinel
  end

  test "maps application startup failures without exposing their details" do
    sentinel = "sentinel-startup-secret"

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      result: {:error, {:startup_failed, sentinel}}
    )

    error = assert_raise Mix.Error, fn -> run([]) end
    assert error.message =~ "unable to start worker-free reprocessing runtime"
    refute error.message =~ sentinel
    refute_received {:recover_orphans, _}
  end

  test "just recover delegates to the Mix task" do
    {empty, 0} = System.cmd("just", ["--dry-run", "recover"], stderr_to_stdout: true)
    {one, 0} = System.cmd("just", ["--dry-run", "recover", "22"], stderr_to_stdout: true)

    assert String.trim(empty) == "mix context_bot.recover"
    assert String.trim(one) == "mix context_bot.recover 22"
  end

  defp run(arguments) do
    Mix.Task.reenable("context_bot.recover")
    RecoverTask.run(arguments)
  end

  defp shell_output do
    collect_shell_output([])
    |> Enum.reverse()
    |> Enum.join("\n")
    |> then(&(&1 <> if(&1 == "", do: "", else: "\n")))
  end

  defp collect_shell_output(output) do
    receive do
      {:mix_shell, :info, [line]} -> collect_shell_output([line | output])
      {:mix_shell, :error, [line]} -> collect_shell_output([line | output])
    after
      0 -> output
    end
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp restore_env(key, :missing), do: Application.delete_env(:context_bot, key)
  defp restore_env(key, value), do: Application.put_env(:context_bot, key, value)
end
