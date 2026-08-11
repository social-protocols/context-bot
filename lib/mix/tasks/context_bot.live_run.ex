defmodule Mix.Tasks.ContextBot.LiveRun do
  @moduledoc "Runs one durable public invocation and publishes its reply from a local runtime."

  # The private orchestration functions carry the explicit, injectable command boundaries used by
  # the failure-path tests. Grouping them into an untyped options map would hide that contract.
  # credo:disable-for-this-file Credo.Check.Refactor.FunctionArity

  use Mix.Task

  import Ecto.Query

  alias ContextBot.ATProto.PublicClient
  alias ContextBot.DryRun.Interrupts
  alias ContextBot.LiveRun
  alias ContextBot.LiveRun.Progress
  alias ContextBot.LiveRun.Runtime
  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @requirements ["app.config"]
  @shortdoc "Process one public mention and publish a live Bluesky reply"
  @default_database "data/live-demo.db"
  @default_owner_retry_ms 100

  @impl Mix.Task
  def run([post]) do
    config = Application.get_env(:context_bot, __MODULE__, [])
    service = Keyword.get(config, :service, LiveRun)
    runtime = Keyword.get(config, :runtime, Runtime)
    progress_module = Keyword.get(config, :progress, Progress)
    interrupts = Keyword.get(config, :interrupts, Interrupts)
    resolver = Keyword.get(config, :resolver, PublicClient)
    settled_cost = Keyword.get(config, :settled_cost, &settled_cost/1)
    owner_retry_ms = Keyword.get(config, :owner_retry_ms, @default_owner_retry_ms)
    settings = Application.fetch_env!(:context_bot, :settings)
    database = System.get_env("CONTEXT_BOT_LIVE_DATABASE_PATH", @default_database)

    validate_runtime!(settings, owner_retry_ms)
    database = configure_runtime!(runtime, database)
    uri = resolve!(service, post, resolver)
    print_mode(settings, uri)

    case find!(service, uri) do
      %Invocation{stage: :complete} = complete ->
        print_identity(complete, :complete)
        print_complete(service, complete, settings.bot_handle, settled_cost.(complete))

      %Invocation{stage: stage} = terminal when stage in [:failed, :ineligible] ->
        print_identity(terminal, :terminal)
        fail_invocation(terminal)

      %Invocation{} = existing ->
        run_existing(
          service,
          runtime,
          progress_module,
          interrupts,
          existing,
          database,
          settings,
          settled_cost,
          owner_retry_ms
        )

      nil ->
        acquire_or_wait_for_receipt(
          service,
          runtime,
          progress_module,
          interrupts,
          uri,
          database,
          settings,
          settled_cost,
          owner_retry_ms
        )
    end
  end

  def run(_arguments), do: Mix.raise("expected exactly one invocation URL")

  defp run_existing(
         service,
         runtime,
         progress_module,
         interrupts,
         invocation,
         database,
         settings,
         settled_cost,
         owner_retry_ms
       ) do
    case acquire_owner!(runtime, database) do
      {:ok, owner} ->
        run_as_owner(
          service,
          runtime,
          progress_module,
          interrupts,
          owner,
          invocation,
          :attached,
          settings,
          settled_cost
        )

      :contended ->
        observe_contended(
          service,
          runtime,
          progress_module,
          interrupts,
          invocation.invocation_uri,
          database,
          settings,
          settled_cost,
          owner_retry_ms
        )
    end
  end

  defp acquire_or_wait_for_receipt(
         service,
         runtime,
         progress_module,
         interrupts,
         uri,
         database,
         settings,
         settled_cost,
         owner_retry_ms
       ) do
    case acquire_owner!(runtime, database) do
      {:ok, owner} ->
        prepare_and_run_owner(
          service,
          runtime,
          progress_module,
          interrupts,
          owner,
          uri,
          settings,
          settled_cost
        )

      :contended ->
        case find!(service, uri) do
          %Invocation{} = invocation ->
            observe_invocation(
              service,
              progress_module,
              interrupts,
              invocation,
              :attached,
              settings,
              settled_cost
            )

          nil ->
            Process.sleep(owner_retry_ms)

            acquire_or_wait_for_receipt(
              service,
              runtime,
              progress_module,
              interrupts,
              uri,
              database,
              settings,
              settled_cost,
              owner_retry_ms
            )
        end
    end
  end

  defp observe_contended(
         service,
         runtime,
         progress_module,
         interrupts,
         uri,
         database,
         settings,
         settled_cost,
         owner_retry_ms
       ) do
    case find!(service, uri) do
      %Invocation{} = invocation ->
        observe_invocation(
          service,
          progress_module,
          interrupts,
          invocation,
          :attached,
          settings,
          settled_cost
        )

      nil ->
        Process.sleep(owner_retry_ms)

        acquire_or_wait_for_receipt(
          service,
          runtime,
          progress_module,
          interrupts,
          uri,
          database,
          settings,
          settled_cost,
          owner_retry_ms
        )
    end
  end

  defp prepare_and_run_owner(
         service,
         runtime,
         progress_module,
         interrupts,
         owner,
         uri,
         settings,
         settled_cost
       )
       when is_function(settled_cost, 1) do
    authenticate!(runtime, owner)
    {invocation, disposition} = prepare!(service, uri)

    case disposition do
      :complete ->
        print_identity(invocation, disposition)
        print_complete(service, invocation, settings.bot_handle, settled_cost.(invocation))

      :terminal ->
        print_identity(invocation, disposition)
        fail_invocation(invocation)

      active when active in [:created, :attached] ->
        run_owned_invocation(
          service,
          runtime,
          progress_module,
          interrupts,
          owner,
          invocation,
          active,
          settings,
          settled_cost
        )
    end
  after
    stop_runtime!(runtime, owner)
  end

  defp run_as_owner(
         service,
         runtime,
         progress_module,
         interrupts,
         owner,
         invocation,
         disposition,
         settings,
         settled_cost
       ) do
    authenticate!(runtime, owner)

    run_owned_invocation(
      service,
      runtime,
      progress_module,
      interrupts,
      owner,
      invocation,
      disposition,
      settings,
      settled_cost
    )
  after
    stop_runtime!(runtime, owner)
  end

  defp run_owned_invocation(
         service,
         runtime,
         progress_module,
         interrupts,
         owner,
         invocation,
         disposition,
         settings,
         settled_cost
       ) do
    print_identity(invocation, disposition)

    with_progress(progress_module, interrupts, invocation, settings, fn progress ->
      start_workers!(runtime, owner, invocation)
      result = await_with_progress(service, invocation, progress_module, progress)
      print_result(result, service, settings.bot_handle, settled_cost)
    end)
  end

  defp observe_invocation(
         service,
         progress_module,
         interrupts,
         invocation,
         disposition,
         settings,
         settled_cost
       ) do
    print_identity(invocation, disposition)

    with_progress(progress_module, interrupts, invocation, settings, fn progress ->
      result = await_with_progress(service, invocation, progress_module, progress)
      print_result(result, service, settings.bot_handle, settled_cost)
    end)
  end

  defp with_progress(progress_module, interrupts, invocation, settings, callback) do
    progress =
      progress_module.start(invocation,
        anthropic_timeout_ms: settings.anthropic_http_timeout_ms
      )

    token = install_interrupts!(interrupts, progress_module, progress)

    try do
      callback.(progress)
    after
      progress_module.finish(progress)
      interrupts.remove(token)
    end
  end

  defp validate_runtime!(settings, owner_retry_ms) do
    validate_bot_disabled!(settings)
    validate_present!(settings.bot_did, "BOT_DID")
    validate_present!(settings.bot_handle, "BOT_HANDLE")
    validate_present!(settings.bot_pds_url, "BOT_PDS_URL")
    validate_budget!(settings.anthropic_daily_budget_microdollars)
    validate_present!(System.get_env("BOT_APP_PASSWORD"), "BOT_APP_PASSWORD")
    validate_present!(Application.get_env(:context_bot, :anthropic_api_key), "ANTHROPIC_API_KEY")

    unless is_integer(owner_retry_ms) and owner_retry_ms > 0 do
      Mix.raise("live-run command configuration is invalid")
    end
  end

  defp validate_bot_disabled!(settings) do
    if Settings.bot_enabled?(settings), do: Mix.raise("live run requires BOT_ENABLED=false")
  end

  defp validate_present!(value, name) do
    unless present?(value), do: Mix.raise("#{name} is required for a live run")
  end

  defp validate_budget!(value) do
    unless is_integer(value) and value > 0 do
      Mix.raise("ANTHROPIC_DAILY_BUDGET_USD is required for a live run")
    end
  end

  defp configure_runtime!(runtime, database) do
    case runtime.configure_and_start(database, []) do
      {:ok, configured} when is_binary(configured) and configured != "" ->
        configured

      {:error, reason} ->
        Mix.raise("unable to start safe live-run application: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to start safe live-run application: runtime_failure")
    end
  end

  defp resolve!(service, post, resolver) do
    case service.resolve(post, resolver) do
      {:ok, uri} when is_binary(uri) and uri != "" ->
        uri

      {:error, reason} ->
        Mix.raise("unable to resolve live invocation: #{safe_prepare_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to resolve live invocation: public_service_failure")
    end
  end

  defp find!(service, uri) do
    case service.find(uri) do
      nil ->
        nil

      %Invocation{dry_run: false, invocation_uri: ^uri, id: id} = invocation
      when is_integer(id) ->
        invocation

      {:error, :contradictory_invocations, ids} when is_list(ids) ->
        Mix.raise("unable to select live invocation: contradictory_invocations")

      _invalid_result ->
        Mix.raise("unable to select live invocation: public_service_failure")
    end
  end

  defp prepare!(service, uri) do
    case service.prepare(uri, []) do
      {:ok, %Invocation{id: id, dry_run: false} = invocation, disposition}
      when is_integer(id) and disposition in [:created, :attached, :complete, :terminal] ->
        {invocation, disposition}

      {:error, :active_invocation, %{id: id, uri: _active_uri}} when is_integer(id) ->
        Mix.raise("unable to prepare live invocation: active_invocation_id=#{id}")

      {:error, reason} ->
        Mix.raise("unable to prepare live invocation: #{safe_prepare_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to prepare live invocation: public_service_failure")
    end
  end

  defp acquire_owner!(runtime, database) do
    case runtime.try_acquire_owner(database, []) do
      {:ok, owner} when is_pid(owner) ->
        {:ok, owner}

      {:error, :runtime_owned} ->
        :contended

      {:error, reason} ->
        Mix.raise("unable to acquire safe live-run runtime: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to acquire safe live-run runtime: runtime_failure")
    end
  end

  defp authenticate!(runtime, owner) do
    case runtime.authenticate(owner, []) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to authenticate live-run bot: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to authenticate live-run bot: runtime_failure")
    end
  end

  defp start_workers!(runtime, owner, invocation) do
    case runtime.start_workers(owner, invocation, []) do
      :ok ->
        :ok

      {:error, :active_invocation, %{id: id, uri: _active_uri}} when is_integer(id) ->
        Mix.raise("unable to start safe live-run workers: active_invocation_id=#{id}")

      {:error, reason} ->
        Mix.raise("unable to start safe live-run workers: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to start safe live-run workers: runtime_failure")
    end
  end

  defp stop_runtime!(runtime, owner) do
    case runtime.stop(owner) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to stop safe live-run workers: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to stop safe live-run workers: runtime_failure")
    end
  end

  defp install_interrupts!(interrupts, progress_module, progress) do
    case interrupts.install(self()) do
      {:ok, token} ->
        token

      {:error, _reason} ->
        progress_module.finish(progress)
        Mix.raise("unable to install live-run signal handlers")
    end
  end

  defp await_with_progress(service, invocation, progress_module, progress) do
    owner = self()
    token = make_ref()

    task =
      Task.async(fn ->
        service.await(invocation,
          on_update: fn current -> send(owner, {token, :progress, current}) end
        )
      end)

    Process.unlink(task.pid)
    await_foreground(token, task, invocation.id, progress_module, progress)
  end

  defp await_foreground(token, task, invocation_id, progress_module, progress) do
    task_ref = task.ref

    receive do
      {^token, :progress, invocation} ->
        progress = progress_module.update(progress, invocation)
        await_foreground(token, task, invocation_id, progress_module, progress)

      {^task_ref, result} ->
        _shutdown_result = Task.shutdown(task, 0)
        result

      {:context_bot_interrupt, signal} when signal in [:sigint, :sigterm] ->
        Task.shutdown(task, 5_000)
        {:error, {:interrupted, invocation_id}}

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        {:error, :await_failed}
    after
      100 ->
        progress = progress_module.tick(progress)
        await_foreground(token, task, invocation_id, progress_module, progress)
    end
  end

  defp print_mode(settings, uri) do
    Mix.shell().info("mode=live_public_reply")
    Mix.shell().info("bot_did=#{settings.bot_did}")
    Mix.shell().info("invocation_uri=#{uri}")
  end

  defp print_identity(invocation, disposition) do
    Mix.shell().info("live_run_id=#{invocation.id}")
    Mix.shell().info("live_run_disposition=#{disposition}")
  end

  defp print_result(result, service, handle, settled_cost) do
    case result do
      {:ok, settled} ->
        print_complete(service, settled, handle, settled_cost.(settled))

      {:deferred, deferred} ->
        Mix.shell().info("status=deferred_budget")
        Mix.shell().info("defer_until=#{datetime(deferred.defer_until)}")
        Mix.raise("live run deferred by the configured Anthropic daily budget")

      {:error, %Invocation{} = failed} ->
        fail_invocation(failed)

      {:error, {:interrupted, invocation_id}} when is_integer(invocation_id) ->
        Mix.shell().info("status=interrupted")
        Mix.shell().info("live_run_id=#{invocation_id}")
        Mix.raise("live run interrupted; durable invocation id=#{invocation_id}")

      {:error, reason} when is_atom(reason) ->
        Mix.raise("live run did not settle: #{reason}")

      _invalid_result ->
        Mix.raise("live run did not settle: public_service_failure")
    end
  end

  @spec fail_invocation(Invocation.t()) :: no_return()
  defp fail_invocation(failed) do
    Mix.shell().info("status=failed")
    Mix.shell().info("failure_category=#{failure_category(failed.failure_category)}")
    Mix.shell().info("completed_at=#{datetime(failed.completed_at)}")
    Mix.raise("live run failed at stage=#{failed.stage}")
  end

  defp print_complete(service, invocation, handle, cost_microdollars) do
    reply_url =
      case service.reply_url(invocation, handle) do
        {:ok, url} when is_binary(url) and url != "" ->
          url

        {:error, reason} ->
          Mix.raise("unable to render live reply URL: #{safe_prepare_error(reason)}")

        _invalid_result ->
          Mix.raise("unable to render live reply URL: public_service_failure")
      end

    totals = get_in(invocation.anthropic_usage || %{}, ["totals"]) || %{}

    Mix.shell().info("status=complete")
    Mix.shell().info("reply_url=#{reply_url}")

    Mix.shell().info(
      "usage input_tokens=#{integer(totals["input_tokens"])} " <>
        "output_tokens=#{integer(totals["output_tokens"])} " <>
        "tool_uses=#{integer((invocation.anthropic_usage || %{})["tool_uses"])} " <>
        "cost_microdollars=#{integer(cost_microdollars)}"
    )
  end

  defp settled_cost(invocation) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation.id)
    |> select([entry], entry.settled_microdollars)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp safe_prepare_error({:transient, _detail}), do: "public_service_unavailable"
  defp safe_prepare_error({:rate_limited, _retry_after}), do: "public_service_rate_limited"
  defp safe_prepare_error(:timeout), do: "public_service_timeout"
  defp safe_prepare_error(:response_too_large), do: "public_service_response_too_large"
  defp safe_prepare_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_prepare_error(_reason), do: "public_service_failure"

  defp safe_runtime_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_runtime_error(_reason), do: "runtime_failure"

  defp failure_category(category) when is_atom(category), do: Atom.to_string(category)
  defp failure_category(_category), do: "unknown"

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(_value), do: "unknown"

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
