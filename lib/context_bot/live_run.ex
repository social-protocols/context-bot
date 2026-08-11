defmodule ContextBot.LiveRun do
  @moduledoc """
  Creates or observes one durable, operator-selected public invocation.
  """

  import Ecto.Query

  alias ContextBot.ATProto.{ATURI, PublicClient}
  alias ContextBot.LiveRun.InvocationPost
  alias ContextBot.{Repo, Settings}
  alias ContextBot.Workflow.{Invocation, Store}

  @thread_worker "ContextBot.Workers.ThreadWorker"
  @default_timeout_ms 900_000
  @default_poll_interval_ms 250

  @spec resolve(String.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def resolve(reference, resolver \\ PublicClient),
    do: InvocationPost.resolve(reference, resolver)

  @spec prepare(String.t(), keyword()) ::
          {:ok, Invocation.t(), :created | :attached | :complete | :terminal}
          | {:error, term()}
  def prepare(uri, options \\ [])

  def prepare(uri, options) when is_binary(uri) and is_list(options) do
    invocation_post = Keyword.get(options, :invocation_post, InvocationPost)
    settings = Keyword.get_lazy(options, :settings, &configured_settings/0)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)

    with %Settings{} <- settings,
         true <- is_function(now, 0),
         {:ok, receipt} <- invocation_post.fetch(uri, settings, options),
         %DateTime{} = timestamp <- now.() do
      Store.create_or_attach_live_run(receipt, timestamp, &thread_job/2)
    else
      false -> {:error, :invalid_input}
      %Settings{} -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_input}
    end
  end

  def prepare(_uri, _options), do: {:error, :invalid_input}

  @spec find(String.t()) ::
          Invocation.t() | nil | {:error, :contradictory_invocations, [pos_integer()]}
  def find(uri) when is_binary(uri) and uri != "" do
    matches =
      Invocation
      |> where([invocation], invocation.dry_run == false and invocation.invocation_uri == ^uri)
      |> order_by([invocation], asc: invocation.id)
      |> Repo.all()

    case matches do
      [] -> nil
      [invocation] -> invocation
      contradictory -> {:error, :contradictory_invocations, Enum.map(contradictory, & &1.id)}
    end
  end

  def find(_uri), do: nil

  @spec await(Invocation.t(), keyword()) ::
          {:ok, Invocation.t()}
          | {:error, Invocation.t()}
          | {:deferred, Invocation.t()}
          | {:error, :timeout | :not_found | :invalid_input | :interrupted}
  def await(invocation, options \\ [])

  def await(%Invocation{id: id, dry_run: false}, options)
      when is_integer(id) and is_list(options) do
    wait = %{
      id: id,
      timeout_ms: Keyword.get(options, :timeout_ms, @default_timeout_ms),
      poll_interval_ms: Keyword.get(options, :poll_interval_ms, @default_poll_interval_ms),
      sleep: Keyword.get(options, :sleep, &Process.sleep/1),
      monotonic_ms:
        Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      on_update: Keyword.get(options, :on_update, fn _invocation -> :ok end),
      interrupt: Keyword.get(options, :interrupt?, fn -> false end)
    }

    if valid_wait_options?(wait) do
      wait = Map.put(wait, :deadline, wait.monotonic_ms.() + wait.timeout_ms)
      await_loop(wait, nil)
    else
      {:error, :invalid_input}
    end
  end

  def await(%Invocation{}, _options), do: {:error, :invalid_input}
  def await(_invocation, _options), do: {:error, :invalid_input}

  @spec reply_url(Invocation.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :invalid_handle | :invalid_input | :invalid_reply_uri}
  def reply_url(%Invocation{stage: :complete, reply_uri: reply_uri}, handle)
      when is_binary(handle) do
    with :ok <- valid_handle(handle),
         {:ok, %{rkey: rkey}} <- parse_reply_uri(reply_uri) do
      {:ok, "https://bsky.app/profile/#{handle}/post/#{rkey}"}
    end
  end

  def reply_url(%Invocation{}, _handle), do: {:error, :invalid_input}
  def reply_url(_invocation, _handle), do: {:error, :invalid_input}

  defp await_loop(wait, last_stage) do
    case Repo.get(Invocation, wait.id) do
      %Invocation{} = invocation ->
        last_stage = notify_stage(invocation, last_stage, wait.on_update)

        case invocation.stage do
          :complete -> {:ok, invocation}
          stage when stage in [:failed, :ineligible] -> {:error, invocation}
          :deferred_budget -> {:deferred, invocation}
          _nonterminal -> await_nonterminal(wait, last_stage)
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp await_nonterminal(wait, last_stage) do
    cond do
      wait.interrupt.() ->
        {:error, :interrupted}

      wait.monotonic_ms.() >= wait.deadline ->
        {:error, :timeout}

      true ->
        wait.sleep.(wait.poll_interval_ms)

        if wait.interrupt.() do
          {:error, :interrupted}
        else
          await_loop(wait, last_stage)
        end
    end
  end

  defp notify_stage(%Invocation{stage: stage}, stage, _on_update), do: stage

  defp notify_stage(%Invocation{stage: stage} = invocation, _last_stage, on_update) do
    on_update.(invocation)
    stage
  end

  defp valid_wait_options?(wait) do
    is_integer(wait.timeout_ms) and wait.timeout_ms >= 0 and
      is_integer(wait.poll_interval_ms) and wait.poll_interval_ms > 0 and
      is_function(wait.sleep, 1) and is_function(wait.monotonic_ms, 0) and
      is_function(wait.on_update, 1) and is_function(wait.interrupt, 0)
  end

  defp valid_handle(handle) do
    if handle == String.trim(handle) and String.match?(handle, ~r/\A[a-zA-Z0-9.-]+\z/) and
         String.contains?(handle, ".") do
      :ok
    else
      {:error, :invalid_handle}
    end
  end

  defp parse_reply_uri(reply_uri) do
    case ATURI.parse(reply_uri) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_reply_uri}
    end
  end

  defp thread_job(uri, cid) do
    Oban.Job.new(%{"uri" => uri, "cid" => cid}, worker: @thread_worker, queue: :thread)
  end

  defp configured_settings, do: Application.fetch_env!(:context_bot, :settings)
end
