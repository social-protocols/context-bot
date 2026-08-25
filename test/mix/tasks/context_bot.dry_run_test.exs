defmodule Mix.Tasks.ContextBot.DryRunTest.Events do
  @moduledoc false

  def record(event) do
    events = Application.fetch_env!(:context_bot, __MODULE__)[:events]
    Agent.update(events, &[event | &1])
  end

  def all do
    events = Application.fetch_env!(:context_bot, __MODULE__)[:events]
    Agent.get(events, &Enum.reverse/1)
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Service do
  @moduledoc false

  alias Mix.Tasks.ContextBot.DryRunTest.Events

  def prepare(post, question, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record({:prepare, post, question, options})
    send(config[:test_pid], {:prepare, post, question, options})
    config[:prepare_result]
  end

  def await(invocation, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record({:await, invocation.id, options})
    send(config[:test_pid], {:await, invocation.id, options})

    if config[:report_await_pid] do
      send(config[:test_pid], {:await_pid, self()})
    end

    Enum.each(Keyword.get(config, :updates, []), options[:on_update])
    Process.sleep(Keyword.get(config, :await_delay_ms, 0))

    case config[:await_result] do
      callback when is_function(callback, 1) -> callback.(options)
      result -> result
    end
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Progress do
  @moduledoc false

  alias Mix.Tasks.ContextBot.DryRunTest.Events

  def start(invocation, options) do
    test_pid = Application.fetch_env!(:context_bot, __MODULE__)[:test_pid]
    Events.record({:progress_start, invocation.id, options})
    send(test_pid, {:progress_start, invocation.id, options})
    %{test_pid: test_pid, invocation_id: invocation.id}
  end

  def update(state, invocation) do
    Events.record({:progress_update, invocation.id, invocation.stage})
    send(state.test_pid, {:progress_update, invocation.id, invocation.stage})
    state
  end

  def tick(state) do
    Events.record({:progress_tick, state.invocation_id})
    send(state.test_pid, {:progress_tick, state.invocation_id})
    state
  end

  def finish(state) do
    Events.record({:progress_finish, state.invocation_id})
    send(state.test_pid, {:progress_finish, state.invocation_id})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Runtime do
  @moduledoc false

  alias Mix.Tasks.ContextBot.DryRunTest.Events

  def ensure_application_started do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record(:base_application_started)
    send(config[:test_pid], :base_application_started)
    config[:application_result]
  end

  def try_acquire_owner(options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record({:owner_acquire, options})
    send(config[:test_pid], {:owner_acquire, options})

    case config[:acquire_owner] do
      callback when is_function(callback, 0) -> callback.()
      nil -> {:ok, self()}
    end
  end

  def start_workers(owner, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record({:workers_started, owner, options})
    send(config[:test_pid], {:workers_started, owner, options})
    config[:workers_result]
  end

  def stop(owner) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    Events.record({:runtime_stopped, owner})
    send(config[:test_pid], {:runtime_stopped, owner})
    Keyword.get(config, :stop_result, :ok)
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest.Interrupts do
  @moduledoc false

  alias Mix.Tasks.ContextBot.DryRunTest.Events

  def install(owner) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    token = make_ref()
    Events.record({:interrupts_installed, token})
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
    Events.record({:interrupts_removed, token})
    send(config[:test_pid], {:interrupts_removed, token})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.DryRunTest do
  use ExUnit.Case, async: false

  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation
  alias Mix.Tasks.ContextBot.DryRun, as: DryRunTask
  alias Mix.Tasks.ContextBot.DryRunTest.{Events, Interrupts, Progress, Runtime, Service}

  setup do
    original_shell = Mix.shell()
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_key = Application.get_env(:context_bot, :anthropic_api_key, :missing)
    original_task = Application.get_env(:context_bot, Mix.Tasks.ContextBot.DryRun, :missing)
    original_service = Application.get_env(:context_bot, Service, :missing)
    original_runtime = Application.get_env(:context_bot, Runtime, :missing)
    original_progress = Application.get_env(:context_bot, Progress, :missing)
    original_interrupts = Application.get_env(:context_bot, Interrupts, :missing)
    original_events = Application.get_env(:context_bot, Events, :missing)

    events = start_supervised!({Agent, fn -> [] end})

    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(
      :context_bot,
      :settings,
      Settings.load(anthropic_daily_budget_usd: "20.000000")
    )

    Application.put_env(:context_bot, :anthropic_api_key, "task-test-provider-key")

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      acquire_owner: fn -> {:ok, self()} end,
      workers_result: :ok
    )

    Application.put_env(:context_bot, Events, events: events)
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
      restore_env(Events, original_events)
    end)

    :ok
  end

  test "rejects wrong arity before starting runtime or creating state" do
    assert_raise Mix.Error, ~r/exactly a post and question/, fn -> run([]) end
    assert_raise Mix.Error, ~r/exactly a post and question/, fn -> run(["one"]) end

    assert_raise Mix.Error, ~r/exactly a post and question/, fn ->
      run(["one", "two", "three"])
    end

    refute_received :base_application_started
    refute_received {:prepare, _, _, _}
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
    refute_received :base_application_started
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
    refute_received :base_application_started
    refute_received {:prepare, _, _, _}
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
      prepare_result: {:ok, %{invocation | stage: :capturing_thread}, :created},
      await_result: {:ok, invocation}
    )

    assert :ok = run(["https://bsky.app/profile/example.test/post/3abc", "What's missing?"])

    assert [
             :base_application_started,
             {:prepare, "https://bsky.app/profile/example.test/post/3abc", "What's missing?", []},
             {:progress_start, 42, progress_options},
             {:interrupts_installed, token},
             {:owner_acquire, []},
             {:workers_started, owner, []},
             {:await, 42, await_options},
             {:runtime_stopped, owner},
             {:progress_finish, 42},
             {:interrupts_removed, token}
           ] = Events.all()

    assert owner == self()
    assert is_function(await_options[:on_update], 1)
    assert progress_options[:anthropic_timeout_ms] == 300_000

    output = shell_output()
    assert output =~ "dry_run_id=42"
    assert output =~ "dry_run_disposition=created"
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
    assert length(Regex.scan(~r/^dry_run_disposition=created$/m, output)) == 1
  end

  test "prints explicit zero usage for a provider-free capability answer" do
    invocation = %Invocation{
      id: 43,
      dry_run: true,
      stage: :complete,
      selected_reply:
        "I can't analyze videos yet, so I can't reliably answer a question that may depend on this clip.",
      anthropic_usage: %{
        "totals" => %{"input_tokens" => 0, "output_tokens" => 0},
        "response_count" => 0,
        "tool_uses" => 0
      }
    }

    Application.put_env(:context_bot, Mix.Tasks.ContextBot.DryRun,
      service: Service,
      runtime: Runtime,
      progress: Progress,
      interrupts: Interrupts,
      settled_cost: fn _invocation -> 0 end
    )

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, %{invocation | stage: :capturing_thread}, :created},
      await_result: {:ok, invocation}
    )

    assert :ok = run(["https://bsky.app/profile/example.test/post/video", "Is this AI?"])

    output = shell_output()
    assert output =~ "status=complete"
    assert output =~ "input_tokens=0"
    assert output =~ "output_tokens=0"
    assert output =~ "tool_uses=0"
    assert output =~ "cost_microdollars=0"
    refute output =~ "researching"
  end

  test "attaches to pending work and prints only safe identity metadata" do
    invocation = %Invocation{id: 42, dry_run: true, stage: :capturing_thread}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :attached},
      await_result: {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
    )

    assert :ok =
             run([
               "https://bsky.app/profile/private.example/post/secret",
               "private question with task-test-provider-key"
             ])

    output = shell_output()
    assert length(Regex.scan(~r/^dry_run_id=42$/m, output)) == 1
    assert length(Regex.scan(~r/^dry_run_disposition=attached$/m, output)) == 1
    refute output =~ "private"
    refute output =~ "task-test-provider-key"
  end

  test "a contending command only observes work that settles under the current owner" do
    invocation = %Invocation{id: 49, dry_run: true, stage: :capturing_thread}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :attached},
      await_result: {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      acquire_owner: fn -> {:error, :runtime_owned} end,
      workers_result: :ok
    )

    assert :ok = run(["post", "question"])

    assert_received {:owner_acquire, []}
    assert_received {:await, 49, _options}
    refute_received {:workers_started, _owner, _options}
    refute_received {:runtime_stopped, _owner}
  end

  test "a contender takes ownership and starts catch-up after the prior owner exits" do
    invocation = %Invocation{id: 50, dry_run: true, stage: :capturing_thread}
    test_pid = self()
    acquisitions = start_supervised!({Agent, fn -> 0 end}, id: :ownership_attempts)

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :attached},
      await_delay_ms: 500,
      await_result: {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      acquire_owner: fn ->
        attempt = Agent.get_and_update(acquisitions, &{&1, &1 + 1})
        if attempt == 0, do: {:error, :runtime_owned}, else: {:ok, test_pid}
      end,
      workers_result: :ok
    )

    assert :ok = run(["post", "question"])

    assert_received {:owner_acquire, []}
    assert_received {:owner_acquire, []}
    refute_received {:owner_acquire, []}
    assert_received {:workers_started, ^test_pid, []}
    refute_received {:workers_started, _owner, _options}
    assert_received {:runtime_stopped, ^test_pid}
    refute_received {:runtime_stopped, _owner}
  end

  test "takeover re-observes an unaffordable due deferral with normal settlement semantics" do
    invocation = %Invocation{
      id: 52,
      dry_run: true,
      stage: :deferred_budget,
      defer_until: ~U[2026-08-10 18:00:00.000000Z]
    }

    test_pid = self()
    acquisitions = start_supervised!({Agent, fn -> 0 end}, id: :due_ownership_attempts)

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :attached},
      await_result: fn options ->
        if options[:wait_for_due_deferred] do
          Process.sleep(500)
          {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
        else
          {:deferred, invocation}
        end
      end
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      acquire_owner: fn ->
        attempt = Agent.get_and_update(acquisitions, &{&1, &1 + 1})
        if attempt == 0, do: {:error, :runtime_owned}, else: {:ok, test_pid}
      end,
      workers_result: :ok
    )

    error = assert_raise Mix.Error, fn -> run(["post", "question"]) end
    assert error.message =~ "deferred by the configured Anthropic daily budget"

    assert_received {:await, 52, contender_options}
    assert contender_options[:wait_for_due_deferred]
    assert_received {:await, 52, owner_options}
    refute owner_options[:wait_for_due_deferred]
    assert_received {:workers_started, ^test_pid, []}
    assert_received {:runtime_stopped, ^test_pid}
  end

  test "a contender stops its observer task when a later ownership attempt fails" do
    invocation = %Invocation{id: 51, dry_run: true, stage: :capturing_thread}
    acquisitions = start_supervised!({Agent, fn -> 0 end}, id: :failed_ownership_attempts)

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :attached},
      report_await_pid: true,
      await_delay_ms: 5_000,
      await_result: {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      acquire_owner: fn ->
        attempt = Agent.get_and_update(acquisitions, &{&1, &1 + 1})

        if attempt == 0,
          do: {:error, :runtime_owned},
          else: {:error, :runtime_lock_failed}
      end,
      workers_result: :ok
    )

    error = assert_raise Mix.Error, fn -> run(["post", "question"]) end
    assert error.message =~ "runtime_lock_failed"
    assert_received {:await_pid, await_pid}
    refute Process.alive?(await_pid)
    refute_received {:workers_started, _owner, _options}
    refute_received {:runtime_stopped, _owner}
  end

  test "cleans up progress and signal handlers when workers cannot start after preparation" do
    invocation = %Invocation{id: 47, dry_run: true, stage: :capturing_thread}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :created},
      await_result: :unused
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      workers_result: {:error, :startup_recovery_failed}
    )

    error =
      assert_raise Mix.Error, fn ->
        run(["https://bsky.app/profile/private.example/post/secret", "private question"])
      end

    assert error.message =~ "unable to start safe dry-run workers"
    refute error.message =~ "private"
    assert_received {:progress_start, 47, _options}
    assert_received {:interrupts_installed, token}
    assert_received {:workers_started, owner, []}
    assert owner == self()
    assert_received {:runtime_stopped, ^owner}
    assert_received {:progress_finish, 47}
    assert_received {:interrupts_removed, ^token}
    refute_received {:await, 47, _options}
  end

  test "reports a finite error when worker shutdown cannot be confirmed" do
    invocation = %Invocation{id: 53, dry_run: true, stage: :capturing_thread}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :created},
      await_result: {:ok, %{invocation | stage: :complete, selected_reply: "Done."}}
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      workers_result: :ok,
      stop_result: {:error, :worker_shutdown_failed}
    )

    error = assert_raise Mix.Error, fn -> run(["post", "question"]) end
    assert error.message =~ "worker_shutdown_failed"
    assert_received {:runtime_stopped, owner}
    assert owner == self()
    assert_received {:progress_finish, 53}
    assert_received {:interrupts_removed, _token}
  end

  test "turns malformed preparation results into a finite content-safe error" do
    target = "https://bsky.app/profile/sentinel-target/post/sentinel-post"
    question = "sentinel-question"
    provider = "sentinel-provider"
    credential = "sentinel-credential"

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result:
        {:unexpected,
         %{target: target, question: question, provider: provider, credential: credential}},
      await_result: :unused
    )

    error = assert_raise Mix.Error, fn -> run([target, question]) end

    assert error.message =~ "public_service_failure"
    refute error.message =~ target
    refute error.message =~ question
    refute error.message =~ provider
    refute error.message =~ credential

    output = shell_output()
    refute output =~ target
    refute output =~ question
    refute output =~ provider
    refute output =~ credential
  end

  test "turns malformed successful preparation results into a finite content-safe error" do
    target = "https://bsky.app/profile/sentinel-target/post/sentinel-post"
    question = "sentinel-question"
    provider = "sentinel-provider"
    credential = "sentinel-credential"

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result:
        {:ok, %{target: target, question: question, provider: provider, credential: credential},
         :created},
      await_result: :unused
    )

    error = assert_raise Mix.Error, fn -> run([target, question]) end

    assert error.message =~ "public_service_failure"
    refute error.message =~ target
    refute error.message =~ question
    refute error.message =~ provider
    refute error.message =~ credential

    output = shell_output()
    refute output =~ target
    refute output =~ question
    refute output =~ provider
    refute output =~ credential
  end

  test "turns malformed worker startup results into a finite content-safe error" do
    target = "https://bsky.app/profile/sentinel-target/post/sentinel-post"
    question = "sentinel-question"
    provider = "sentinel-provider"
    credential = "sentinel-credential"
    invocation = %Invocation{id: 48, dry_run: true, stage: :capturing_thread}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, invocation, :created},
      await_result: :unused
    )

    Application.put_env(:context_bot, Runtime,
      test_pid: self(),
      application_result: :ok,
      workers_result:
        {:unexpected,
         %{target: target, question: question, provider: provider, credential: credential}}
    )

    error = assert_raise Mix.Error, fn -> run([target, question]) end

    assert error.message =~ "runtime_failure"
    refute error.message =~ target
    refute error.message =~ question
    refute error.message =~ provider
    refute error.message =~ credential

    output = shell_output()
    refute output =~ target
    refute output =~ question
    refute output =~ provider
    refute output =~ credential
  end

  test "forwards durable stage changes and animates while awaiting" do
    created = %Invocation{id: 45, dry_run: true, stage: :capturing_thread}
    researching = %{created | stage: :researching}
    complete = %{created | stage: :complete, selected_reply: "Done."}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:ok, created, :created},
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
      prepare_result: {:ok, created, :created},
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
    assert_received {:runtime_stopped, owner}
    assert owner == self()
    refute_received {:runtime_stopped, _owner}

    output = shell_output()
    assert length(Regex.scan(~r/^dry_run_id=46$/m, output)) == 1
    assert length(Regex.scan(~r/^status=interrupted$/m, output)) == 1
    refute output =~ "private"
    refute output =~ "task-test-provider-key"
  end

  test "turns structured public-read failures into a finite safe Mix error" do
    Application.put_env(:context_bot, Service,
      test_pid: self(),
      prepare_result: {:error, {:transient, 503}},
      await_result: :unused
    )

    assert_raise Mix.Error, ~r/public_service_unavailable/, fn -> run(["post", "question"]) end
    assert_received :base_application_started
    assert_received {:prepare, "post", "question", []}
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
      prepare_result: {:ok, %{deferred | stage: :capturing_thread}, :created},
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
      prepare_result: {:ok, %{failed | stage: :capturing_thread}, :created},
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
