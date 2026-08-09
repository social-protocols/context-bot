defmodule ContextBot.DryRun.Runtime do
  @moduledoc false

  @safe_queues [:research, :thread]

  @spec ensure_started() :: :ok | {:error, atom()}
  def ensure_started do
    cond do
      Process.whereis(ContextBot.ATProto.Session) ->
        {:error, :atproto_session_running}

      is_nil(Oban.whereis(Oban)) ->
        start_minimal_oban()

      safe_existing_oban?() ->
        :ok

      true ->
        {:error, :unsafe_oban_runtime}
    end
  end

  defp start_minimal_oban do
    options =
      :context_bot
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:queues, thread: 1, research: 1)
      |> Keyword.put(:plugins, [])
      |> Keyword.delete(:testing)

    case Oban.start_link(options) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        if safe_existing_oban?(), do: :ok, else: {:error, :unsafe_oban_runtime}

      {:error, _reason} ->
        {:error, :oban_start_failed}
    end
  end

  defp safe_existing_oban? do
    config = Oban.config(Oban)

    config.testing == :disabled and config.plugins == [] and
      Enum.sort(Keyword.keys(config.queues)) == @safe_queues
  rescue
    _missing_or_invalid_runtime -> false
  end
end
