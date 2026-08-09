defmodule ContextBot.DryRun.Runtime do
  @moduledoc false

  alias ContextBot.Settings

  @safe_queues [:dry_research, :dry_thread]
  @public_children [ContextBot.ATProto.Session, ContextBot.Mentions.Poller]

  @spec ensure_started() :: :ok | {:error, atom()}
  def ensure_started do
    settings = Application.fetch_env!(:context_bot, :settings)

    if Settings.bot_enabled?(settings) do
      {:error, :bot_enabled}
    else
      with {:ok, _applications} <- Application.ensure_all_started(:context_bot),
           false <- public_child_running?() do
        ensure_oban()
      else
        true -> {:error, :public_worker_running}
        {:error, _reason} -> {:error, :application_start_failed}
      end
    end
  end

  @doc false
  @spec safe_oban_config?(Oban.Config.t(), [String.t()] | nil) :: boolean()
  def safe_oban_config?(config, active_queues \\ nil)

  def safe_oban_config?(%Oban.Config{} = config, active_queues) do
    configured_queues = Enum.sort(Keyword.keys(config.queues))
    active_queues = active_queues || Enum.map(configured_queues, &Atom.to_string/1)

    config.testing == :disabled and config.plugins == [] and
      configured_queues == @safe_queues and
      Enum.all?(config.queues, fn {_queue, options} -> options[:limit] == 1 end) and
      Enum.sort(active_queues) == Enum.map(@safe_queues, &Atom.to_string/1)
  end

  def safe_oban_config?(_config, _active_queues), do: false

  defp ensure_oban do
    cond do
      is_nil(Oban.whereis(Oban)) -> start_minimal_oban()
      safe_existing_oban?() -> :ok
      true -> {:error, :unsafe_oban_runtime}
    end
  end

  defp start_minimal_oban do
    options =
      :context_bot
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:queues, dry_thread: 1, dry_research: 1)
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
    safe_oban_config?(Oban.config(Oban), active_queue_names()) and not public_child_running?()
  rescue
    _missing_or_invalid_runtime -> false
  end

  defp active_queue_names do
    match = [{{{Oban, {:producer, :"$1"}}, :"$2", :_}, [], [:"$1"]}]
    Oban.Registry.select(match)
  end

  defp public_child_running? do
    case Process.whereis(ContextBot.Supervisor) do
      nil ->
        false

      _pid ->
        ContextBot.Supervisor
        |> Supervisor.which_children()
        |> Enum.any?(fn {id, pid, _type, _modules} -> id in @public_children and is_pid(pid) end)
    end
  end
end
