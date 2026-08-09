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

    with {:ok, target_uri} <- reference_module.normalize(post_reference, resolver) do
      Store.create_dry_run(target_uri, question, now.(), &thread_job/2)
    end
  end

  def create(_post_reference, _question, _options), do: {:error, :invalid_input}

  @spec await(Invocation.t(), keyword()) ::
          {:ok, Invocation.t()}
          | {:error, Invocation.t()}
          | {:deferred, Invocation.t()}
          | {:error, :timeout | :not_found | :invalid_input}
  def await(invocation, options \\ [])

  def await(%Invocation{id: id, dry_run: true}, options) when is_integer(id) do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, @default_poll_interval_ms)
    sleep = Keyword.get(options, :sleep, &Process.sleep/1)

    monotonic_ms =
      Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    if valid_wait_options?(timeout_ms, poll_interval_ms, sleep, monotonic_ms) do
      deadline = monotonic_ms.() + timeout_ms
      await_loop(id, deadline, poll_interval_ms, sleep, monotonic_ms)
    else
      {:error, :invalid_input}
    end
  end

  def await(%Invocation{}, _options), do: {:error, :invalid_input}

  defp await_loop(id, deadline, poll_interval_ms, sleep, monotonic_ms) do
    case Repo.get(Invocation, id) do
      %Invocation{stage: :complete} = invocation ->
        {:ok, invocation}

      %Invocation{stage: :failed} = invocation ->
        {:error, invocation}

      %Invocation{stage: :deferred_budget} = invocation ->
        {:deferred, invocation}

      %Invocation{} ->
        if monotonic_ms.() >= deadline do
          {:error, :timeout}
        else
          sleep.(poll_interval_ms)
          await_loop(id, deadline, poll_interval_ms, sleep, monotonic_ms)
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp valid_wait_options?(timeout_ms, poll_interval_ms, sleep, monotonic_ms) do
    is_integer(timeout_ms) and timeout_ms >= 0 and is_integer(poll_interval_ms) and
      poll_interval_ms > 0 and is_function(sleep, 1) and is_function(monotonic_ms, 0)
  end

  defp thread_job(uri, cid) do
    Oban.Job.new(
      %{"uri" => uri, "cid" => cid},
      worker: @thread_worker,
      queue: :thread
    )
  end
end
