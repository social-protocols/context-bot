defmodule Mix.Tasks.ContextBot.ReprocessTest.Service do
  @moduledoc false

  def reprocess(invocation_id, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:reprocess, invocation_id, options})
    config[:result]
  end
end

defmodule Mix.Tasks.ContextBot.ReprocessTest do
  use ExUnit.Case, async: false

  alias ContextBot.Workflow.Invocation
  alias Mix.Tasks.ContextBot.Reprocess, as: ReprocessTask
  alias Mix.Tasks.ContextBot.ReprocessTest.Service

  setup do
    original_shell = Mix.shell()
    original_task = Application.get_env(:context_bot, ReprocessTask, :missing)
    original_service = Application.get_env(:context_bot, Service, :missing)

    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(:context_bot, ReprocessTask,
      reprocessor: Service,
      application_starter: fn ->
        send(self(), :application_started)
        :ok
      end,
      now: fn -> ~U[2026-08-11 22:30:00.000000Z] end
    )

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      result: {:ok, %Invocation{id: 42, stage: :thread_ready}}
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      restore_env(ReprocessTask, original_task)
      restore_env(Service, original_service)
    end)

    :ok
  end

  test "loads configuration before starting the application" do
    assert ReprocessTask.__info__(:attributes)[:requirements] == ["app.config"]
  end

  test "requires exactly one positive integer invocation ID before startup" do
    for arguments <- [[], ["1", "2"], ["0"], ["-1"], ["nope"], ["1suffix"]] do
      assert_raise Mix.Error, ~r/positive integer invocation ID/, fn -> run(arguments) end
      refute_received :application_started
      refute_received {:reprocess, _, _}
    end
  end

  test "starts the application and prints only the reopened identity" do
    assert :ok = run(["42"])

    assert_received :application_started
    assert_received {:reprocess, 42, [now: ~U[2026-08-11 22:30:00.000000Z]]}
    assert shell_output() == "status=reopened\ninvocation_id=42\n"
  end

  test "maps every guarded refusal to a stable content-safe error" do
    sentinel = "sentinel-private-provider-body"

    for {reason, message} <- [
          {:not_found, "invocation not found"},
          {:not_reprocessable, "invocation is not reprocessable"},
          {:ambiguous_provider_attempt, "provider attempt is ambiguous"},
          {:missing_recorded_response, "recorded response is missing"},
          {:invalid_recorded_response, "recorded response is not replayable"},
          {{:unexpected, sentinel}, "reprocessing failed"}
        ] do
      Application.put_env(:context_bot, Service,
        test_pid: self(),
        result: {:error, reason}
      )

      error = assert_raise Mix.Error, fn -> run(["42"]) end
      assert error.message =~ message
      refute error.message =~ sentinel
    end
  end

  test "maps application startup failures without exposing their details" do
    sentinel = "sentinel-startup-secret"

    Application.put_env(:context_bot, ReprocessTask,
      reprocessor: Service,
      application_starter: fn -> {:error, {:startup_failed, sentinel}} end,
      now: fn -> ~U[2026-08-11 22:30:00.000000Z] end
    )

    error = assert_raise Mix.Error, fn -> run(["42"]) end
    assert error.message =~ "unable to start application"
    refute error.message =~ sentinel
    refute_received {:reprocess, _, _}
  end

  test "just reprocess delegates to the Mix task" do
    {recipe, 0} =
      System.cmd("just", ["--dry-run", "reprocess", "42"], stderr_to_stdout: true)

    assert recipe == "mix context_bot.reprocess '42'\n"
  end

  defp run(arguments) do
    Mix.Task.reenable("context_bot.reprocess")
    ReprocessTask.run(arguments)
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
