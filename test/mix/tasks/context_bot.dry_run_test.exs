defmodule Mix.Tasks.ContextBot.DryRunTest.Service do
  @moduledoc false

  def create(post, question, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:create, post, question, options})
    config[:create_result]
  end

  def await(invocation, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:await, invocation.id, options})

    Enum.each(Keyword.get(config, :updates, []), options[:on_update])
    Process.sleep(Keyword.get(config, :await_delay_ms, 0))
    config[:await_result]
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Progress do
  @moduledoc false

  def start(invocation, options) do
    test_pid = Application.fetch_env!(:context_bot, __MODULE__)[:test_pid]
    send(test_pid, {:progress_start, invocation.id, options})
    %{test_pid: test_pid, invocation_id: invocation.id}
  end

  def update(state, invocation) do
    send(state.test_pid, {:progress_update, invocation.id, invocation.stage})
    state
  end

  def tick(state) do
    send(state.test_pid, {:progress_tick, state.invocation_id})
    state
  end

  def finish(state) do
    send(state.test_pid, {:progress_finish, state.invocation_id})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Runtime do
  @moduledoc false

  def ensure_started do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], :runtime_started)
    config[:result]
  end

  def stop do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], :runtime_stopped)
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Interrupts do
  @moduledoc false

  def install(owner) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    token = make_ref()
    send(config[:test_pid], {:interrupts_installed, token})

    if signal = config[:signal] do
      spawn(fn ->
        Process.sleep(20)
        send(owner, {:context_bot_interrupt, signal})
      end)
    end

    {:ok, token}
  end

  def remove(token) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:interrupts_removed, token})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest do
  use ExUnit.Case, async: false

  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation
  alias Mix.Tasks.ContextBot.DryRun, as: DryRunTask
  alias Mix.Tasks.ContextBot.DryRunTest.{Interrupts, Progress, Runtime, Service}

  setup do
    original_shell = Mix.shell()
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_key = Application.get_env(:context_bot, :anthropic_api_key, :missing)
    original_task = Application.get_env(:context_bot, Mix.Tasks.ContextBot.DryRun, :missing)
    original_service = Application.get_env(:context_bot, Service, :missing)
    original_runtime = Application.get_env(:context_bot, Runtime, :missing)
    original_progress = Application.get_env(:context_bot, Progress, :missing)
    original_interrupts = Application.get_env(:context_bot, Interrupts, :missing)

    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(
      :context_bot,
      :settings,
      Settings.load(anthropic_daily_budget_usd: "20.000000")
    )

    Application.put_env(:context_bot, :anthropic_api_key, "task-test-provider-key")
    Application.put_env(:context_bot, Runtime, test_pid: self(), result: :ok)
    Application.put_env(:context_bot, Progress, test_pid: self())
    Application.put_env(:context_bot, Interrupts, test_pid: self())

    Application.put_env(:context_bot, Mix.Tasks.ContextBot.DryRun,
      service: Service,
      runtime: Runtime,
      progress: Progress,
      interrupts: Interrupts,
      settled_cost: fn _invocation -> 321 end
    )

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:context_bot, :settings, original_settings)
      restore_env(:anthropic_api_key, original_key)
      restore_env(Mix.Tasks.ContextBot.DryRun, original_task)
      restore_env(Service, original_service)
      restore_env(Runtime, original_runtime)
      restore_env(Progress, original_progress)
      restore_env(Interrupts, original_interrupts)
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

  test "loads configuration without starting the application before validation" do
    assert DryRunTask.__info__(:attributes)[:requirements] == ["app.config"]
  end

  test "just dry-run delegates to the signal-safe wrapper and retains dotenv loading" do
    {recipe, 0} =
      System.cmd("just", ["--dry-run", "dry-run", "post", "question"], stderr_to_stdout: true)

    assert recipe == "./dry-run.sh 'post' 'question'\n"
    assert File.read!("justfile") =~ "set dotenv-load := true"
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
      selected_reply: "A concise\e[31m tested\nanswer.\e[0m",
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

    assert_received {:await, 42, await_options}
    assert is_function(await_options[:on_update], 1)
    assert_received {:progress_start, 42, progress_options}
    assert progress_options[:anthropic_timeout_ms] == 300_000
    assert_received {:progress_finish, 42}

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
    refute output =~ "\e"
    assert length(Regex.scan(~r/^dry_run_id=42$/m, output)) == 1
  end

  test "forwards durable stage changes and animates while awaiting" do
    created = %Invocation{id: 45, dry_run: true, stage: :capturing_thread}
    researching = %{created | stage: :researching}
    complete = %{created | stage: :complete, selected_reply: "Done."}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:ok, created},
      updates: [created, researching, complete],
      await_delay_ms: 120,
      await_result: {:ok, complete}
    )

    assert :ok = run(["post", "question"])
    assert_received {:progress_update, 45, :capturing_thread}
    assert_received {:progress_update, 45, :researching}
    assert_received {:progress_update, 45, :complete}
    assert_received {:progress_tick, 45}
    assert_received {:progress_finish, 45}
  end

  test "interrupts a blocked await, stops workers once, and prints only durable safe state" do
    created = %Invocation{id: 46, dry_run: true, stage: :researching}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:ok, created},
      await_delay_ms: :infinity,
      await_result: :never
    )

    Application.put_env(:context_bot, Interrupts, test_pid: self(), signal: :sigterm)

    error =
      assert_raise Mix.Error, fn ->
        run([
          "https://bsky.app/profile/private.example/post/secret",
          "private question with task-test-provider-key"
        ])
      end

    assert error.message =~ "interrupted"
    assert error.message =~ "46"
    refute error.message =~ "private"
    refute error.message =~ "task-test-provider-key"

    assert_received {:interrupts_installed, token}
    assert_received {:interrupts_removed, ^token}
    assert_received {:await, 46, _options}
    assert_received {:progress_finish, 46}
    assert_received :runtime_stopped
    refute_received :runtime_stopped

    output = shell_output()
    assert length(Regex.scan(~r/^dry_run_id=46$/m, output)) == 1
    assert length(Regex.scan(~r/^status=interrupted$/m, output)) == 1
    refute output =~ "private"
    refute output =~ "task-test-provider-key"
  end

  test "turns structured public-read failures into a finite safe Mix error" do
    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:error, {:transient, 503}},
      await_result: :unused
    )

    assert_raise Mix.Error, ~r/public_service_unavailable/, fn -> run(["post", "question"]) end
    assert_received :runtime_started
    assert_received {:create, "post", "question", []}
  end

  test "prints safe failure and budget timing metadata" do
    deferred = %Invocation{
      id: 43,
      dry_run: true,
      stage: :deferred_budget,
      defer_until: ~U[2026-08-10 00:00:00.000000Z]
    }

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:ok, %{deferred | stage: :capturing_thread}},
      await_result: {:deferred, deferred}
    )

    assert_raise Mix.Error, ~r/deferred/, fn -> run(["post", "question"]) end
    output = shell_output()
    assert output =~ "status=deferred_budget"
    assert output =~ "defer_until=2026-08-10T00:00:00.000000Z"

    failed = %Invocation{
      id: 44,
      dry_run: true,
      stage: :failed,
      failure_category: :provider_response
    }

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      create_result: {:ok, %{failed | stage: :capturing_thread}},
      await_result: {:error, failed}
    )

    assert_raise Mix.Error, ~r/failed/, fn -> run(["post", "question"]) end
    output = shell_output()
    assert output =~ "status=failed"
    assert output =~ "failure_category=provider_response"
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
