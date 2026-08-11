defmodule Mix.Tasks.ContextBot.LiveRunTest.Events do
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

defmodule Mix.Tasks.ContextBot.LiveRunTest.Service do
  @moduledoc false

  alias Mix.Tasks.ContextBot.LiveRunTest.Events

  def resolve(post, resolver) do
    config = config()
    Events.record({:resolve, post, resolver})
    result(config, :resolve_result, [post])
  end

  def find(uri) do
    config = config()
    Events.record({:find, uri})
    result(config, :find_result, [uri])
  end

  def prepare(uri, options) do
    config = config()
    Events.record({:prepare, uri, options})
    result(config, :prepare_result, [uri, options])
  end

  def await(invocation, options) do
    config = config()
    Events.record({:await, invocation.id, options})

    if config[:report_await_pid], do: send(config[:test_pid], {:await_pid, self()})
    Enum.each(Keyword.get(config, :updates, []), options[:on_update])
    Process.sleep(Keyword.get(config, :await_delay_ms, 0))
    result(config, :await_result, [invocation, options])
  end

  def reply_url(invocation, handle) do
    Events.record({:reply_url, invocation.id, handle})
    result(config(), :reply_url_result, [invocation, handle])
  end

  defp config, do: Application.fetch_env!(:context_bot, __MODULE__)

  defp result(config, key, arguments) do
    case Keyword.fetch!(config, key) do
      callback when is_function(callback) -> apply(callback, arguments)
      value -> value
    end
  end
end

defmodule Mix.Tasks.ContextBot.LiveRunTest.Runtime do
  @moduledoc false

  alias Mix.Tasks.ContextBot.LiveRunTest.Events

  def configure_and_start(database, options) do
    config = config()
    Events.record({:configure_and_start, database, options})
    result(config, :configure_result, [database, options])
  end

  def try_acquire_owner(database, options) do
    config = config()
    Events.record({:owner_acquire, database, options})
    result(config, :owner_result, [database, options])
  end

  def authenticate(owner, options) do
    config = config()
    Events.record({:authenticate, owner, options})
    result(config, :authenticate_result, [owner, options])
  end

  def start_workers(owner, invocation, options) do
    config = config()
    Events.record({:workers_started, owner, invocation.id, options})
    result(config, :workers_result, [owner, invocation, options])
  end

  def stop(owner) do
    config = config()
    Events.record({:runtime_stopped, owner})
    result(config, :stop_result, [owner])
  end

  defp config, do: Application.fetch_env!(:context_bot, __MODULE__)

  defp result(config, key, arguments) do
    case Keyword.fetch!(config, key) do
      callback when is_function(callback) -> apply(callback, arguments)
      value -> value
    end
  end
end

defmodule Mix.Tasks.ContextBot.LiveRunTest.Progress do
  @moduledoc false

  alias Mix.Tasks.ContextBot.LiveRunTest.Events

  def start(invocation, options) do
    Events.record({:progress_start, invocation.id, options})
    %{id: invocation.id}
  end

  def update(state, invocation) do
    Events.record({:progress_update, invocation.id, invocation.stage})
    state
  end

  def tick(state) do
    Events.record({:progress_tick, state.id})
    state
  end

  def finish(state) do
    Events.record({:progress_finish, state.id})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.LiveRunTest.Interrupts do
  @moduledoc false

  alias Mix.Tasks.ContextBot.LiveRunTest.Events

  def install(owner) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    token = make_ref()
    Events.record({:interrupts_installed, token})

    if signal = config[:signal] do
      spawn(fn ->
        Process.sleep(20)
        send(owner, {:context_bot_interrupt, signal})
      end)
    end

    {:ok, token}
  end

  def remove(token) do
    Events.record({:interrupts_removed, token})
    :ok
  end
end

defmodule Mix.Tasks.ContextBot.LiveRunTest do
  use ExUnit.Case, async: false

  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation
  alias Mix.Tasks.ContextBot.LiveRun, as: LiveRunTask

  alias Mix.Tasks.ContextBot.LiveRunTest.{
    Events,
    Interrupts,
    Progress,
    Runtime,
    Service
  }

  @post "https://bsky.app/profile/actor.test/post/3invoke"
  @uri "at://did:plc:actor/app.bsky.feed.post/3invoke"
  @database "data/live-demo-test.db"

  setup do
    original_shell = Mix.shell()
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_key = Application.get_env(:context_bot, :anthropic_api_key, :missing)
    original_task = Application.get_env(:context_bot, Mix.Tasks.ContextBot.LiveRun, :missing)
    original_events = Application.get_env(:context_bot, Events, :missing)
    original_password = System.get_env("BOT_APP_PASSWORD")
    original_database = System.get_env("CONTEXT_BOT_LIVE_DATABASE_PATH")

    events = start_supervised!({Agent, fn -> [] end})
    Mix.shell(Mix.Shell.Process)
    flush_mailbox()

    Application.put_env(:context_bot, :settings, settings())
    Application.put_env(:context_bot, :anthropic_api_key, "sentinel-anthropic-secret")
    Application.put_env(:context_bot, Events, events: events)

    Application.put_env(:context_bot, Runtime,
      configure_result: {:ok, Path.expand(@database)},
      owner_result: {:ok, self()},
      authenticate_result: :ok,
      workers_result: :ok,
      stop_result: :ok
    )

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:ok, @uri},
      find_result: nil,
      prepare_result: {:ok, invocation(:capturing_thread), :created},
      await_result: {:ok, invocation(:complete)},
      reply_url_result: {:ok, "https://bsky.app/profile/getcontext.bot/post/3reply"}
    )

    Application.put_env(:context_bot, Interrupts, [])

    Application.put_env(:context_bot, Mix.Tasks.ContextBot.LiveRun,
      service: Service,
      runtime: Runtime,
      progress: Progress,
      interrupts: Interrupts,
      resolver: :test_resolver,
      settled_cost: fn _invocation -> 321 end,
      owner_retry_ms: 1
    )

    System.put_env("BOT_APP_PASSWORD", "sentinel-bot-secret")
    System.put_env("CONTEXT_BOT_LIVE_DATABASE_PATH", @database)

    on_exit(fn ->
      Mix.shell(original_shell)
      Application.put_env(:context_bot, :settings, original_settings)
      restore_env(:anthropic_api_key, original_key)
      restore_env(Mix.Tasks.ContextBot.LiveRun, original_task)
      restore_env(Events, original_events)
      Application.delete_env(:context_bot, Service)
      Application.delete_env(:context_bot, Runtime)
      Application.delete_env(:context_bot, Progress)
      Application.delete_env(:context_bot, Interrupts)
      restore_system_env("BOT_APP_PASSWORD", original_password)
      restore_system_env("CONTEXT_BOT_LIVE_DATABASE_PATH", original_database)
    end)

    :ok
  end

  test "requires exactly one invocation URL before any runtime work" do
    for arguments <- [[], ["one", "two"]] do
      assert_raise Mix.Error, ~r/exactly one invocation URL/, fn -> run(arguments) end
    end

    assert LiveRunTask.__info__(:attributes)[:requirements] == ["app.config"]
    assert Events.all() == []
  end

  test "validates live identity, budget, and secrets before runtime work" do
    current = Application.fetch_env!(:context_bot, :settings)

    for settings <- [
          %{current | bot_enabled: true},
          %{current | bot_did: nil},
          %{current | bot_handle: nil},
          %{current | bot_pds_url: nil},
          %{current | anthropic_daily_budget_microdollars: nil}
        ] do
      Application.put_env(:context_bot, :settings, settings)
      assert_raise Mix.Error, fn -> run([@post]) end
    end

    Application.put_env(:context_bot, :settings, current)
    System.delete_env("BOT_APP_PASSWORD")
    assert_raise Mix.Error, ~r/BOT_APP_PASSWORD/, fn -> run([@post]) end

    System.put_env("BOT_APP_PASSWORD", "sentinel-bot-secret")
    Application.delete_env(:context_bot, :anthropic_api_key)
    assert_raise Mix.Error, ~r/ANTHROPIC_API_KEY/, fn -> run([@post]) end
    assert Events.all() == []
  end

  test "runs the authenticated one-shot workflow in strict order and prints a safe result" do
    assert :ok = run([@post])

    events = Events.all()

    assert [
             {:configure_and_start, @database, []},
             {:resolve, @post, :test_resolver},
             {:find, @uri},
             {:owner_acquire, expanded_database, []},
             {:authenticate, owner, []},
             {:prepare, @uri, []},
             {:progress_start, 42, progress_options},
             {:interrupts_installed, token},
             {:workers_started, owner, 42, []},
             {:await, 42, await_options},
             {:reply_url, 42, "getcontext.bot"},
             {:progress_finish, 42},
             {:interrupts_removed, token},
             {:runtime_stopped, owner}
           ] = events

    assert expanded_database == Path.expand(@database)
    assert owner == self()
    assert is_function(await_options[:on_update], 1)
    assert progress_options[:anthropic_timeout_ms] == 300_000

    output = shell_output()
    assert output =~ "mode=live_public_reply"
    assert output =~ "bot_did=did:plc:contextbot"
    assert output =~ "invocation_uri=#{@uri}"
    assert output =~ "live_run_id=42"
    assert output =~ "live_run_disposition=created"
    assert output =~ "status=complete"
    assert output =~ "reply_url=https://bsky.app/profile/getcontext.bot/post/3reply"
    assert output =~ "cost_microdollars=321"
    refute output =~ "sentinel-anthropic-secret"
    refute output =~ "sentinel-bot-secret"
    refute output =~ @post
  end

  test "an already complete row reports its reply without authentication or workers" do
    complete = invocation(:complete)

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:ok, @uri},
      find_result: complete,
      prepare_result: :unused,
      await_result: :unused,
      reply_url_result: {:ok, "https://bsky.app/profile/getcontext.bot/post/3reply"}
    )

    assert :ok = run([@post])

    assert Events.all() == [
             {:configure_and_start, @database, []},
             {:resolve, @post, :test_resolver},
             {:find, @uri},
             {:reply_url, 42, "getcontext.bot"}
           ]

    assert shell_output() =~ "status=complete"
  end

  test "an already failed row reports durable failure without authentication or workers" do
    failed = %{invocation(:failed) | failure_category: :provider_response}

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:ok, @uri},
      find_result: failed,
      prepare_result: :unused,
      await_result: :unused,
      reply_url_result: :unused
    )

    assert_raise Mix.Error, ~r/failed/, fn -> run([@post]) end

    assert Events.all() == [
             {:configure_and_start, @database, []},
             {:resolve, @post, :test_resolver},
             {:find, @uri}
           ]

    output = shell_output()
    assert output =~ "live_run_disposition=terminal"
    assert output =~ "status=failed"
    assert output =~ "failure_category=provider_response"
  end

  test "a contending command observes the selected durable row without starting workers" do
    pending = invocation(:researching)

    Application.put_env(:context_bot, Runtime,
      configure_result: {:ok, Path.expand(@database)},
      owner_result: {:error, :runtime_owned},
      authenticate_result: :ok,
      workers_result: :ok,
      stop_result: :ok
    )

    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:ok, @uri},
      find_result: pending,
      prepare_result: :unused,
      await_result: {:ok, invocation(:complete)},
      reply_url_result: {:ok, "https://bsky.app/profile/getcontext.bot/post/3reply"}
    )

    assert :ok = run([@post])
    assert Enum.any?(Events.all(), &match?({:await, 42, _}, &1))
    refute Enum.any?(Events.all(), &match?({:authenticate, _, _}, &1))
    refute Enum.any?(Events.all(), &match?({:workers_started, _, _, _}, &1))
  end

  test "a contender takes ownership when the prior owner exits before creating the row" do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :live_owner_attempts)

    Application.put_env(:context_bot, Runtime,
      configure_result: {:ok, Path.expand(@database)},
      owner_result: fn _database, _options ->
        attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
        if attempt == 0, do: {:error, :runtime_owned}, else: {:ok, self()}
      end,
      authenticate_result: :ok,
      workers_result: :ok,
      stop_result: :ok
    )

    assert :ok = run([@post])
    assert Enum.count(Events.all(), &match?({:owner_acquire, _, _}, &1)) == 2
    assert Enum.any?(Events.all(), &match?({:prepare, @uri, []}, &1))
    assert Enum.any?(Events.all(), &match?({:workers_started, _, 42, []}, &1))
  end

  test "terminal failure and budget deferral report only safe durable metadata" do
    for {result, status} <- [
          {{:error, %{invocation(:failed) | failure_category: :provider_response}}, "failed"},
          {{:deferred, %{invocation(:deferred_budget) | defer_until: ~U[2026-08-12 01:00:00Z]}},
           "deferred_budget"}
        ] do
      Application.put_env(:context_bot, Service,
        test_pid: self(),
        resolve_result: {:ok, @uri},
        find_result: nil,
        prepare_result: {:ok, invocation(:capturing_thread), :created},
        await_result: result,
        reply_url_result: :unused
      )

      assert_raise Mix.Error, fn -> run([@post]) end
      output = shell_output()
      assert output =~ "status=#{status}"
      refute output =~ "sentinel-anthropic-secret"
      refute output =~ "sentinel-bot-secret"
    end
  end

  test "interruption stops owned runtime and leaves a resumable public invocation" do
    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:ok, @uri},
      find_result: nil,
      prepare_result: {:ok, invocation(:researching), :created},
      await_delay_ms: :infinity,
      await_result: :never,
      reply_url_result: :unused
    )

    Application.put_env(:context_bot, Interrupts, signal: :sigterm)

    assert_raise Mix.Error, ~r/interrupted/, fn -> run([@post]) end
    assert Enum.any?(Events.all(), &match?({:runtime_stopped, _}, &1))
    assert Enum.any?(Events.all(), &match?({:progress_finish, 42}, &1))

    output = shell_output()
    assert output =~ "status=interrupted"
    assert output =~ "live_run_id=42"
    refute output =~ @post
  end

  test "malformed dependency results become finite content-safe errors" do
    Application.put_env(:context_bot, Service,
      test_pid: self(),
      resolve_result: {:unexpected, %{secret: "sentinel-anthropic-secret", post: @post}},
      find_result: nil,
      prepare_result: :unused,
      await_result: :unused,
      reply_url_result: :unused
    )

    error = assert_raise Mix.Error, fn -> run([@post]) end
    assert error.message =~ "public_service_failure"
    refute error.message =~ "sentinel"
    refute error.message =~ @post
    refute shell_output() =~ @post
  end

  defp settings do
    Settings.load(
      bot_did: "did:plc:contextbot",
      bot_handle: "getcontext.bot",
      bot_pds_url: "https://pds.example",
      anthropic_daily_budget_usd: "20.000000"
    )
  end

  defp invocation(stage) do
    %Invocation{
      id: 42,
      dry_run: false,
      invocation_uri: @uri,
      stage: stage,
      reply_uri: if(stage == :complete, do: "at://did:plc:contextbot/app.bsky.feed.post/3reply"),
      anthropic_usage: %{
        "totals" => %{"input_tokens" => 120, "output_tokens" => 30},
        "tool_uses" => 2
      }
    }
  end

  defp run(arguments), do: LiveRunTask.run(arguments)

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

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
