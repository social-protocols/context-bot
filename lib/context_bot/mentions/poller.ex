defmodule ContextBot.Mentions.Poller do
  @moduledoc """
  Drains direct-mention notification pages into durable workflow receipts.

  Every drain starts at the newest notification page. Cursors are intentionally
  ephemeral backward-pagination tokens, never checkpoints.
  """

  use GenServer

  alias ContextBot.Mentions.Validator
  alias ContextBot.Workflow.Store

  @eligibility_worker "ContextBot.Workflow.EligibilityWorker"
  @default_poll_interval_ms 30_000
  @default_page_cap 5

  @type state :: %{
          client: module(),
          store: module(),
          validator: module(),
          bot_did: String.t(),
          max_pending: pos_integer(),
          page_cap: pos_integer(),
          poll_interval_ms: pos_integer(),
          draining?: boolean()
        }

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name))
  end

  @doc """
  Requests a fresh, newest-first drain.
  """
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server), do: send(server, :poll)

  @doc false
  @spec idle?(GenServer.server()) :: boolean()
  def idle?(server), do: GenServer.call(server, :idle?)

  @impl true
  def init(options) do
    settings = Application.fetch_env!(:context_bot, :settings)

    state = %{
      client: Keyword.get(options, :client, ContextBot.ATProto.ReqClient),
      store: Keyword.get(options, :store, Store),
      validator: Keyword.get(options, :validator, Validator),
      bot_did: Keyword.get(options, :bot_did, settings.bot_did),
      max_pending: Keyword.get(options, :max_pending, settings.max_pending),
      page_cap: Keyword.get(options, :page_cap, @default_page_cap),
      poll_interval_ms: Keyword.get(options, :poll_interval_ms, @default_poll_interval_ms),
      draining?: false
    }

    if Keyword.get(options, :start_immediately, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:idle?, _from, state), do: {:reply, not state.draining?, state}

  @impl true
  def handle_info(:poll, %{draining?: true} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    state = %{state | draining?: true}
    receipts = drain(state, nil, 0, [])
    receive_receipts(state, receipts)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, %{state | draining?: false}}
  end

  defp drain(state, cursor, pages, receipts) do
    case state.client.list_notifications(cursor) do
      {:ok, _status, _headers, %{"notifications" => notifications} = page}
      when is_list(notifications) ->
        case discover_page(state, notifications, receipts) do
          {:halt, discovered} -> discovered
          {:continue, discovered} -> continue_drain(state, page, pages, discovered)
        end

      _error ->
        receipts
    end
  end

  defp continue_drain(state, page, pages, receipts) do
    next_cursor = Map.get(page, "cursor")

    if pages + 1 >= state.page_cap or not is_binary(next_cursor) or next_cursor == "" do
      receipts
    else
      drain(state, next_cursor, pages + 1, receipts)
    end
  end

  defp discover_page(state, notifications, receipts) do
    Enum.reduce_while(notifications, {:continue, receipts}, fn notification, {_status, found} ->
      case notification_reference(notification) do
        {:ok, uri, cid} ->
          handle_reference(state, notification, found, state.store.received?(uri, cid))

        _ ->
          validate_notification(state, notification, found)
      end
    end)
  end

  defp handle_reference(_state, _notification, found, true), do: {:halt, {:halt, found}}

  defp handle_reference(state, notification, found, false),
    do: validate_notification(state, notification, found)

  defp validate_notification(state, notification, found) do
    case state.validator.validate(notification, state.bot_did) do
      {:ok, receipt} -> {:cont, {:continue, [receipt | found]}}
      {:error, _reason} -> {:cont, {:continue, found}}
    end
  end

  defp receive_receipts(state, receipts) do
    Enum.each(receipts, fn receipt ->
      next_job =
        if state.store.pending_capacity_available?(state.max_pending) do
          eligibility_job(receipt)
        end

      state.store.receive_mention(receipt, DateTime.utc_now(), next_job)
    end)
  end

  defp eligibility_job(receipt) do
    Oban.Job.new(
      %{"uri" => receipt.uri, "cid" => receipt.cid},
      worker: @eligibility_worker,
      queue: :eligibility
    )
  end

  defp notification_reference(%{"uri" => uri, "cid" => cid})
       when is_binary(uri) and uri != "" and is_binary(cid) and cid != "",
       do: {:ok, uri, cid}

  defp notification_reference(_notification), do: :error
end
