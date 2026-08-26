defmodule Mix.Tasks.ContextBot.DryRun do
  @moduledoc "Runs one durable, local-only context check against a public Bluesky post."

  use Mix.Task

  import Ecto.Query

  alias ContextBot.{DryRun, LocalMigrate, Repo, Settings}
  alias ContextBot.DryRun.{Interrupts, Progress}
  alias ContextBot.Research.BudgetEntry

  @requirements ["app.config"]
  @shortdoc "Run a durable local context check without posting to Bluesky"
  @owner_retry_ticks 3

  @impl Mix.Task
  def run([post, question]) do
    config = Application.get_env(:context_bot, __MODULE__, [])
    service = Keyword.get(config, :service, DryRun)
    runtime = Keyword.get(config, :runtime, ContextBot.DryRun.Runtime)
    progress_module = Keyword.get(config, :progress, Progress)
    interrupts = Keyword.get(config, :interrupts, Interrupts)
    settled_cost = Keyword.get(config, :settled_cost, &settled_cost/1)
    settings = Application.fetch_env!(:context_bot, :settings)

    validate_runtime!(settings)
    LocalMigrate.ensure_migrated!()
    ensure_application_started!(runtime)

    {invocation, disposition} = prepare!(service, post, question)
    print_identity(invocation, disposition)

    progress =
      progress_module.start(invocation,
        anthropic_timeout_ms: settings.anthropic_http_timeout_ms
      )

    token = install_interrupts!(interrupts, progress_module, progress)

    try do
      {result, _progress} =
        execute_or_observe(service, runtime, invocation, progress_module, progress)

      print_result(result, settled_cost)
    after
      progress_module.finish(progress)
      interrupts.remove(token)
    end
  end

  def run(_arguments), do: Mix.raise("expected exactly a post and question")

  defp print_result(result, settled_cost) do
    case result do
      {:ok, settled} ->
        print_complete(settled, settled_cost.(settled))
        :ok

      {:deferred, deferred} ->
        Mix.shell().info("status=deferred_budget")
        Mix.shell().info("defer_until=#{datetime(deferred.defer_until)}")
        Mix.raise("dry run deferred by the configured Anthropic daily budget")

      {:error, %ContextBot.Workflow.Invocation{} = failed} ->
        Mix.shell().info("status=failed")
        Mix.shell().info("failure_category=#{failure_category(failed.failure_category)}")
        Mix.shell().info("completed_at=#{datetime(failed.completed_at)}")
        Mix.raise("dry run failed at stage=#{failed.stage}")

      {:error, {:interrupted, invocation_id}} when is_integer(invocation_id) ->
        Mix.shell().info("status=interrupted")
        Mix.raise("dry run interrupted; durable invocation id=#{invocation_id}")

      {:error, reason} when is_atom(reason) ->
        Mix.raise("dry run did not settle: #{reason}")
    end
  end

  defp validate_runtime!(settings) do
    if Settings.bot_enabled?(settings), do: Mix.raise("dry run requires BOT_ENABLED=false")

    unless is_integer(settings.anthropic_daily_budget_microdollars) and
             settings.anthropic_daily_budget_microdollars > 0 do
      Mix.raise("ANTHROPIC_DAILY_BUDGET_USD is required for a dry run")
    end

    case Application.get_env(:context_bot, :anthropic_api_key) do
      key when is_binary(key) and key != "" -> :ok
      _missing -> Mix.raise("ANTHROPIC_API_KEY is required for a dry run")
    end
  end

  defp ensure_application_started!(runtime) do
    case runtime.ensure_application_started() do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to start safe dry-run application: #{safe_runtime_error(reason)}")
    end
  end

  defp prepare!(service, post, question) do
    case service.prepare(post, question, []) do
      {:ok, %ContextBot.Workflow.Invocation{id: id} = invocation, disposition}
      when is_integer(id) and disposition in [:created, :attached] ->
        {invocation, disposition}

      {:error, reason} ->
        Mix.raise("unable to prepare dry run: #{safe_prepare_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to prepare dry run: public_service_failure")
    end
  end

  defp execute_or_observe(service, runtime, invocation, progress_module, progress) do
    case acquire_owner!(runtime) do
      {:ok, owner} ->
        try do
          start_workers!(runtime, owner)
          await_with_progress(service, invocation, progress_module, progress)
        after
          stop_runtime!(runtime, owner)
        end

      :contended ->
        await_while_contended(service, runtime, invocation, progress_module, progress)
    end
  end

  defp acquire_owner!(runtime) do
    case runtime.try_acquire_owner([]) do
      {:ok, owner} when is_pid(owner) ->
        {:ok, owner}

      {:error, :runtime_owned} ->
        :contended

      {:error, reason} ->
        Mix.raise("unable to acquire safe dry-run runtime: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to acquire safe dry-run runtime: runtime_failure")
    end
  end

  defp start_workers!(runtime, owner) do
    case runtime.start_workers(owner, []) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to start safe dry-run workers: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to start safe dry-run workers: runtime_failure")
    end
  end

  defp stop_runtime!(runtime, owner) do
    case runtime.stop(owner) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("unable to stop safe dry-run workers: #{safe_runtime_error(reason)}")

      _invalid_result ->
        Mix.raise("unable to stop safe dry-run workers: runtime_failure")
    end
  end

  defp print_identity(invocation, disposition) do
    Mix.shell().info("dry_run_id=#{invocation.id}")
    Mix.shell().info("dry_run_disposition=#{disposition}")
  end

  defp print_complete(invocation, cost_microdollars) do
    totals = get_in(invocation.anthropic_usage || %{}, ["totals"]) || %{}

    Mix.shell().info("status=complete")
    Mix.shell().info("answer=#{one_line(invocation.selected_reply)}")

    Mix.shell().info(
      "usage input_tokens=#{integer(totals["input_tokens"])} " <>
        "output_tokens=#{integer(totals["output_tokens"])} " <>
        "tool_uses=#{integer((invocation.anthropic_usage || %{})["tool_uses"])} " <>
        "cost_microdollars=#{integer(cost_microdollars)}"
    )
  end

  defp install_interrupts!(interrupts, progress_module, progress) do
    case interrupts.install(self()) do
      {:ok, token} ->
        token

      {:error, _reason} ->
        progress_module.finish(progress)
        Mix.raise("unable to install dry-run signal handlers")
    end
  end

  defp await_with_progress(service, invocation, progress_module, progress) do
    {token, task} = start_await_task(service, invocation)

    await_foreground(token, task, invocation.id, progress_module, progress)
  end

  defp await_while_contended(service, runtime, invocation, progress_module, progress) do
    {token, task} =
      start_await_task(service, invocation, wait_for_due_deferred: true)

    resume_as_owner = fn current_progress ->
      await_with_progress(service, invocation, progress_module, current_progress)
    end

    try do
      await_contended(
        token,
        task,
        runtime,
        invocation.id,
        progress_module,
        progress,
        @owner_retry_ticks,
        resume_as_owner
      )
    after
      _shutdown_result = Task.shutdown(task, 0)
    end
  end

  defp start_await_task(service, invocation) do
    start_await_task(service, invocation, [])
  end

  defp start_await_task(service, invocation, await_options) do
    owner = self()
    token = make_ref()

    task =
      Task.async(fn ->
        options =
          Keyword.put(
            await_options,
            :on_update,
            fn current -> send(owner, {token, :progress, current}) end
          )

        service.await(invocation, options)
      end)

    Process.unlink(task.pid)
    {token, task}
  end

  defp await_foreground(token, task, invocation_id, progress_module, progress) do
    task_ref = task.ref

    receive do
      {^token, :progress, invocation} ->
        progress = progress_module.update(progress, invocation)
        await_foreground(token, task, invocation_id, progress_module, progress)

      {^task_ref, result} ->
        _shutdown_result = Task.shutdown(task, 0)
        {result, progress}

      {:context_bot_interrupt, signal} when signal in [:sigint, :sigterm] ->
        Task.shutdown(task, 5_000)
        {{:error, {:interrupted, invocation_id}}, progress}

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        {{:error, :await_failed}, progress}
    after
      100 ->
        progress = progress_module.tick(progress)
        await_foreground(token, task, invocation_id, progress_module, progress)
    end
  end

  defp await_contended(
         token,
         task,
         runtime,
         invocation_id,
         progress_module,
         progress,
         retry_ticks,
         resume_as_owner
       ) do
    task_ref = task.ref

    receive do
      {^token, :progress, invocation} ->
        progress = progress_module.update(progress, invocation)

        await_contended(
          token,
          task,
          runtime,
          invocation_id,
          progress_module,
          progress,
          retry_ticks,
          resume_as_owner
        )

      {^task_ref, result} ->
        _shutdown_result = Task.shutdown(task, 0)
        {result, progress}

      {:context_bot_interrupt, signal} when signal in [:sigint, :sigterm] ->
        Task.shutdown(task, 5_000)
        {{:error, {:interrupted, invocation_id}}, progress}

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        {{:error, :await_failed}, progress}
    after
      100 ->
        progress = progress_module.tick(progress)

        retry_or_continue(
          token,
          task,
          runtime,
          invocation_id,
          progress_module,
          progress,
          retry_ticks,
          resume_as_owner
        )
    end
  end

  defp retry_or_continue(
         token,
         task,
         runtime,
         invocation_id,
         progress_module,
         progress,
         retry_ticks,
         resume_as_owner
       )
       when retry_ticks > 1 do
    await_contended(
      token,
      task,
      runtime,
      invocation_id,
      progress_module,
      progress,
      retry_ticks - 1,
      resume_as_owner
    )
  end

  defp retry_or_continue(
         token,
         task,
         runtime,
         invocation_id,
         progress_module,
         progress,
         _retry_ticks,
         resume_as_owner
       ) do
    case acquire_owner!(runtime) do
      {:ok, owner} ->
        try do
          _shutdown_result = Task.shutdown(task, 0)
          start_workers!(runtime, owner)
          resume_as_owner.(progress)
        after
          _shutdown_result = Task.shutdown(task, 0)
          stop_runtime!(runtime, owner)
        end

      :contended ->
        await_contended(
          token,
          task,
          runtime,
          invocation_id,
          progress_module,
          progress,
          @owner_retry_ticks,
          resume_as_owner
        )
    end
  end

  defp settled_cost(invocation) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation.id)
    |> select([entry], entry.settled_microdollars)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp one_line(value) when is_binary(value) do
    value
    |> String.replace(~r/\x1B\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/[\x00-\x1F\x7F-\x9F]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp one_line(_value), do: ""

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

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
end
