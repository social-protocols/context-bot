defmodule ContextBot.DryRun do
  @moduledoc """
  Creates and observes permanently local, durable context checks.

  Creation only resolves a public post reference and inserts SQLite work. The Oban thread and
  research queues perform provider I/O separately.
  """

  alias ContextBot.ATProto.PublicClient
  alias ContextBot.DryRun.PostReference
  alias ContextBot.{Repo, Workflow.Store}
  alias ContextBot.Workflow.Invocation

  @thread_worker "ContextBot.Workers.ThreadWorker"
  @maximum_question_bytes 10_000
  @default_timeout_ms 900_000
  @default_poll_interval_ms 250

  @spec create(String.t(), String.t(), keyword()) ::
          {:ok, Invocation.t()} | {:error, atom()}
  def create(post_reference, question, options \\ [])

  def create(post_reference, question, options)
      when is_binary(post_reference) and is_binary(question) and is_list(options) do
    reference_module = Keyword.get(options, :post_reference, PostReference)
    resolver = Keyword.get(options, :resolver, PublicClient)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)

    with :ok <- validate_question(question),
         {:ok, target_uri} <- reference_module.normalize(post_reference, resolver) do
      Store.create_dry_run(target_uri, question, now.(), &thread_job/2)
    end
  end

  def create(_post_reference, _question, _options), do: {:error, :invalid_input}

  @spec await(Invocation.t(), keyword()) ::
          {:ok, Invocation.t()}
          | {:error, Invocation.t()}
          | {:deferred, Invocation.t()}
          | {:error, :timeout | :not_found | :invalid_input | :interrupted}
  def await(invocation, options \\ [])

  def await(%Invocation{id: id, dry_run: true}, options) when is_integer(id) do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, @default_poll_interval_ms)
    sleep = Keyword.get(options, :sleep, &Process.sleep/1)
    on_update = Keyword.get(options, :on_update, fn _invocation -> :ok end)
    interrupt? = Keyword.get(options, :interrupt?, fn -> false end)

    monotonic_ms =
      Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    if valid_wait_options?(
         timeout_ms,
         poll_interval_ms,
         sleep,
         monotonic_ms,
         on_update,
         interrupt?
       ) do
      deadline = monotonic_ms.() + timeout_ms

      await_loop(
        id,
        deadline,
        poll_interval_ms,
        sleep,
        monotonic_ms,
        on_update,
        interrupt?,
        nil
      )
    else
      {:error, :invalid_input}
    end
  end

  def await(%Invocation{}, _options), do: {:error, :invalid_input}

  defp await_loop(
         id,
         deadline,
         poll_interval_ms,
         sleep,
         monotonic_ms,
         on_update,
         interrupt?,
         last_stage
       ) do
    case Repo.get(Invocation, id) do
      %Invocation{} = invocation ->
        last_stage = notify_stage(invocation, last_stage, on_update)

        case invocation.stage do
          :complete ->
            {:ok, invocation}

          :failed ->
            {:error, invocation}

          :deferred_budget ->
            {:deferred, invocation}

          _nonterminal ->
            await_nonterminal(
              id,
              deadline,
              poll_interval_ms,
              sleep,
              monotonic_ms,
              on_update,
              interrupt?,
              last_stage
            )
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp await_nonterminal(
         id,
         deadline,
         poll_interval_ms,
         sleep,
         monotonic_ms,
         on_update,
         interrupt?,
         last_stage
       ) do
    cond do
      interrupt?.() ->
        {:error, :interrupted}

      monotonic_ms.() >= deadline ->
        {:error, :timeout}

      true ->
        sleep.(poll_interval_ms)

        resume_after_sleep(
          id,
          deadline,
          poll_interval_ms,
          sleep,
          monotonic_ms,
          on_update,
          interrupt?,
          last_stage
        )
    end
  end

  defp resume_after_sleep(
         id,
         deadline,
         poll_interval_ms,
         sleep,
         monotonic_ms,
         on_update,
         interrupt?,
         last_stage
       ) do
    if interrupt?.() do
      {:error, :interrupted}
    else
      await_loop(
        id,
        deadline,
        poll_interval_ms,
        sleep,
        monotonic_ms,
        on_update,
        interrupt?,
        last_stage
      )
    end
  end

  defp notify_stage(%Invocation{stage: stage}, stage, _on_update), do: stage

  defp notify_stage(%Invocation{stage: stage} = invocation, _last_stage, on_update) do
    on_update.(invocation)
    stage
  end

  defp valid_wait_options?(
         timeout_ms,
         poll_interval_ms,
         sleep,
         monotonic_ms,
         on_update,
         interrupt?
       ) do
    is_integer(timeout_ms) and timeout_ms >= 0 and is_integer(poll_interval_ms) and
      poll_interval_ms > 0 and is_function(sleep, 1) and is_function(monotonic_ms, 0) and
      is_function(on_update, 1) and is_function(interrupt?, 0)
  end

  defp validate_question(question) do
    if String.valid?(question) and byte_size(question) <= @maximum_question_bytes and
         String.trim(question) != "" do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp thread_job(uri, cid) do
    Oban.Job.new(
      %{"uri" => uri, "cid" => cid},
      worker: @thread_worker,
      queue: :dry_thread
    )
  end
end
