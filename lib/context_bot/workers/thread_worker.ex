defmodule ContextBot.Workers.ThreadWorker do
  @moduledoc """
  Fetches and freezes the ancestor-only thread snapshot before research may begin.

  The external fetch and canonicalization run outside SQLite transactions. The completed
  snapshot and future research job are committed together through the workflow store.
  """

  use Oban.Worker, queue: :thread, max_attempts: 10

  import Ecto.Query

  alias ContextBot.ATProto.ReqClient
  alias ContextBot.Repo
  alias ContextBot.Thread.Canonicalizer
  alias ContextBot.Workflow.{Invocation, Store}

  @research_worker "ContextBot.Workers.ResearchWorker"
  @default_fetch_timeout_ms 20_000
  @maximum_backoff_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}})
      when is_binary(uri) and is_binary(cid) do
    case find_invocation(uri, cid) do
      %Invocation{stage: :capturing_thread} = invocation ->
        capture(invocation, dependencies())

      _missing_or_unclaimable ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) when is_integer(attempt) and attempt > 0 do
    exponent = attempt |> Kernel.-(1) |> min(5)
    min(15 * Integer.pow(2, exponent), @maximum_backoff_seconds)
  end

  def backoff(%Oban.Job{}), do: 15

  defp find_invocation(uri, cid) do
    Invocation
    |> where(
      [invocation],
      invocation.invocation_uri == ^uri and invocation.notification_cid == ^cid
    )
    |> Repo.one()
  end

  defp capture(invocation, dependencies) do
    result =
      fetch_with_timeout(
        dependencies.client,
        invocation.invocation_uri,
        dependencies.settings.thread_parent_height,
        dependencies.fetch_timeout_ms
      )

    handle_fetch(result, invocation, dependencies)
  end

  defp fetch_with_timeout(client, uri, parent_height, timeout_ms) do
    task = Task.async(fn -> client.get_post_thread(uri, parent_height) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, {:transient, :transport}}
    end
  end

  defp handle_fetch({:ok, status, _headers, body}, invocation, dependencies)
       when status in 200..299 and is_map(body) do
    with :ok <- within_response_limit(body, dependencies.settings.max_response_bytes),
         {:ok, canonical} <-
           dependencies.canonicalizer.build(body, %{
             bot_did: dependencies.settings.bot_did,
             invocation_uri: invocation.invocation_uri,
             notification_cid: invocation.notification_cid,
             parent_height: dependencies.settings.thread_parent_height
           }) do
      persist_handoff(invocation, body, canonical, dependencies.research_job_builder)
    else
      {:error, :target_unavailable} -> fail_thread(invocation, "target_unavailable")
      {:error, :invalid_thread} -> fail_thread(invocation, "invalid_thread")
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_fetch({:error, :record_not_found}, invocation, _dependencies),
    do: fail_thread(invocation, "target_unavailable")

  defp handle_fetch({:error, {:permanent, _status}}, invocation, _dependencies),
    do: fail_thread(invocation, "target_unavailable")

  defp handle_fetch({:ok, status, _headers, _invalid_body}, invocation, _dependencies)
       when status in 200..299,
       do: fail_thread(invocation, "invalid_thread")

  defp handle_fetch({:error, reason}, _invocation, _dependencies), do: {:error, reason}
  defp handle_fetch(_invalid_response, _invocation, _dependencies), do: {:error, :invalid_thread}

  defp within_response_limit(body, limit) do
    case Jason.encode(body) do
      {:ok, encoded} when byte_size(encoded) <= limit -> :ok
      {:ok, _oversized} -> {:error, :response_too_large}
      {:error, _invalid_json} -> {:error, :invalid_thread}
    end
  end

  defp persist_handoff(invocation, raw_thread, canonical, research_job_builder) do
    next_job = research_job_builder.(invocation)

    attrs = %{
      raw_thread: raw_thread,
      canonical_thread: canonical.text,
      canonical_thread_version: Integer.to_string(canonical.version),
      root_uri: canonical.root["uri"],
      root_cid: canonical.root["cid"],
      current_cid: canonical.current_cid
    }

    case Store.transition(invocation, :capturing_thread, :thread_ready, attrs, next_job) do
      {:ok, _thread_ready} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp fail_thread(invocation, reason) do
    case Store.transition(
           invocation,
           :capturing_thread,
           :failed,
           %{
             failure_category: :thread_unavailable,
             failure_detail: %{"reason" => reason},
             completed_at: DateTime.utc_now()
           },
           nil
         ) do
      {:ok, _failed} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp research_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @research_worker,
      queue: :research
    )
  end

  defp dependencies do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      canonicalizer: Keyword.get(config, :canonicalizer, Canonicalizer),
      client: Keyword.get(config, :client, ReqClient),
      fetch_timeout_ms: Keyword.get(config, :fetch_timeout_ms, @default_fetch_timeout_ms),
      research_job_builder: Keyword.get(config, :research_job_builder, &research_job/1),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end
end
