defmodule ContextBot.Runtime.Drain do
  @moduledoc """
  Stops poller admission and non-drain queues so in-flight research and reply can finish.
  """

  require Logger

  alias ContextBot.Mentions.Poller

  @admission_queues [:eligibility, :thread, :maintenance]

  @spec begin() :: :ok
  def begin do
    pause_admission_queues()
    stop_poller()
    :ok
  catch
    _kind, _reason ->
      Logger.warning("context_bot_drain_failed")
      :ok
  end

  defp stop_poller do
    case Process.whereis(Poller) do
      pid when is_pid(pid) -> Poller.stop_accepting(pid)
      _missing -> :ok
    end
  end

  defp pause_admission_queues do
    Enum.each(@admission_queues, fn queue ->
      case Oban.pause_queue(Oban, queue: queue) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end)
  end
end
