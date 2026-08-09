defmodule Mix.Tasks.ContextBot.DryRunTest.Service do
  @moduledoc false

  def create(post, question, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:create, post, question, options})
    config[:create_result]
  end

  def await(invocation) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:await, invocation.id})
    config[:await_result]
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Runtime do
  @moduledoc false

  def ensure_started do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], :runtime_started)
    config[:result]
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest do
  use ExUnit.Case, async: false

  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation
  alias Mix.Tasks.ContextBot.DryRun, as: DryRunTask
  alias Mix.Tasks.ContextBot.DryRunTest.{Runtime, Service}

  setup do
    original_shell = Mix.shell()
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_key = Application.get_env(:context_bot, :anthropic_api_key, :missing)
    original_task = Application.get_env(:context_bot, Mix.Tasks.ContextBot.DryRun, :missing)
    original_service = Application.get_env(:context_bot, Service, :missing)
    original_runtime = Application.get_env(:context_bot, Runtime, :missing)

    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(
      :context_bot,
      :settings,
      Settings.load(anthropic_daily_budget_usd: "20.000000")
    )

    Application.put_env(:context_bot, :anthropic_api_key, "task-test-provider-key")
    Application.put_env(:context_bot, Runtime, test_pid: self(), result: :ok)

    Application.put_env(:context_bot, Mix.Tasks.ContextBot.DryRun,
      service: Service,
      runtime: Runtime,
      settled_cost: fn _invocation -> 321 end
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:context_bot, :settings, original_settings)
      restore_env(:anthropic_api_key, original_key)
      restore_env(Mix.Tasks.ContextBot.DryRun, original_task)
      restore_env(Service, original_service)
      restore_env(Runtime, original_runtime)
    end)

    :ok
  end

  test "rejects wrong arity before starting runtime or creating state" do
    assert_raise Mix.Error, ~r/exactly a post and question/, fn -> run([]) end
    assert_raise Mix.Error, ~r/exactly a post and question/, fn -> run(["one"]) end

    assert_raise Mix.Error, ~r/exactly a post and question/, fn ->
      run(["one", "two", "three"])
    end

    refute_received :runtime_started
    refute_received {:create, _, _, _}
  end

  test "fails closed when the public bot is enabled" do
    settings = Application.fetch_env!(:context_bot, :settings)
    Application.put_env(:context_bot, :settings, %{settings | bot_enabled: true})

    assert_raise Mix.Error, ~r/BOT_ENABLED=false/, fn -> run(["post", "question"]) end
    refute_received :runtime_started
  end

  test "requires a configured daily budget and Anthropic key before durable work" do
    settings = Application.fetch_env!(:context_bot, :settings)

    Application.put_env(
      :context_bot,
      :settings,
      %{settings | anthropic_daily_budget_microdollars: nil}
    )

    assert_raise Mix.Error, ~r/ANTHROPIC_DAILY_BUDGET_USD/, fn ->
      run(["post", "question"])
    end

    Application.put_env(:context_bot, :settings, settings)
    Application.delete_env(:context_bot, :anthropic_api_key)

    assert_raise Mix.Error, ~r/ANTHROPIC_API_KEY/, fn -> run(["post", "question"]) end
    refute_received :runtime_started
    refute_received {:create, _, _, _}
  end

  test "prints only a compact completed summary" do
    invocation = %Invocation{
      id: 42,
      dry_run: true,
      stage: :complete,
      selected_reply: "A concise tested answer.",
      anthropic_usage: %{
        "totals" => %{"input_tokens" => 120, "output_tokens" => 30},
        "response_count" => 1,
        "tool_uses" => 2
      }
    }

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:ok, %{invocation | stage: :capturing_thread}},
      await_result: {:ok, invocation}
    )

    assert :ok = run(["https://bsky.app/profile/example.test/post/3abc", "What's missing?"])

    assert_received :runtime_started

    assert_received {:create, "https://bsky.app/profile/example.test/post/3abc",
                     "What's missing?", []}

    assert_received {:await, 42}

    output = shell_output()
    assert output =~ "dry_run_id=42"
    assert output =~ "status=complete"
    assert output =~ "answer=A concise tested answer."
    assert output =~ "input_tokens=120"
    assert output =~ "output_tokens=30"
    assert output =~ "tool_uses=2"
    assert output =~ "cost_microdollars=321"
    refute output =~ "task-test-provider-key"
    refute output =~ "canonical thread"
    refute output =~ "headers"
    refute output =~ "raw_body"
  end

  defp run(arguments), do: DryRunTask.run(arguments)

  defp shell_output do
    receive_shell_output([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp receive_shell_output(messages) do
    receive do
      {:mix_shell, :info, message} ->
        receive_shell_output([IO.iodata_to_binary(message) | messages])
    after
      0 -> messages
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
