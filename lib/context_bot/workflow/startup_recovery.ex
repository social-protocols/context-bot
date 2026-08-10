defmodule ContextBot.Workflow.StartupRecovery do
  @moduledoc """
  Completes durable workflow recovery before public Oban consumers start.
  """

  use GenServer

  require Logger

  alias ContextBot.Workflow.Recovery

  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl GenServer
  def init(options) do
    recovery = Keyword.get(options, :recovery, Recovery)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)

    case recovery.recover_orphans(startup?: true, now: now.()) do
      {:ok, summary} ->
        Logger.info("context_bot_startup_recovery", Map.to_list(summary))
        {:ok, %{summary: summary}}

      {:error, _safe_reason} ->
        {:stop, :startup_recovery_failed}
    end
  end
end
