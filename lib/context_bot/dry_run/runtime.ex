defmodule ContextBot.DryRun.Runtime do
  @moduledoc false

  alias ContextBot.{Settings, Workers.DeferredWorker}
  alias ContextBot.Workflow.Recovery

  @safe_queues [:dry_research, :dry_thread]
  @public_children [ContextBot.ATProto.Session, ContextBot.Mentions.Poller]

  @spec ensure_application_started() :: :ok | {:error, atom()}
  def ensure_application_started do
    settings = Application.fetch_env!(:context_bot, :settings)

    if Settings.bot_enabled?(settings) do
      {:error, :bot_enabled}
    else
      with {:ok, _applications} <- Application.ensure_all_started(:context_bot),
           false <- public_child_running?(),
           nil <- Oban.whereis(Oban) do
        :ok
      else
        true -> {:error, :public_worker_running}
        oban_pid when is_pid(oban_pid) -> {:error, :unsafe_oban_runtime}
        {:error, _reason} -> {:error, :application_start_failed}
      end
    end
  end

  @spec start_workers(keyword()) :: :ok | {:error, atom()}
  def start_workers(options \\ []) when is_list(options) do
    recovery = Keyword.get(options, :recovery, Recovery)
    deferred = Keyword.get(options, :deferred, DeferredWorker)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)
    base_ready = Keyword.get(options, :base_ready, &base_application_ready/0)
    settings = Application.fetch_env!(:context_bot, :settings)
    timestamp = now.()

    with :ok <- base_ready.(),
         :ok <- recover_orphans(recovery, timestamp),
         :ok <- reconsider_due(deferred, timestamp, settings) do
      start_minimal_oban()
    end
  end

  @spec stop(keyword()) :: :ok
  def stop(_options \\ []) do
    case Oban.whereis(Oban) do
      nil ->
        :ok

      pid ->
        if safe_existing_oban?() and not public_child_running?() do
          config = Oban.config(Oban)
          _result = Oban.pause_all_queues(Oban)
          Supervisor.stop(pid, :shutdown, config.shutdown_grace_period + 1_000)
        end

        :ok
    end
  catch
    :exit, _reason -> :ok
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

  defp recover_orphans(recovery, now) do
    case recovery.recover_orphans(startup?: true, now: now) do
      {:ok, _summary} -> :ok
      {:error, _reason} -> {:error, :startup_recovery_failed}
      _invalid_result -> {:error, :startup_recovery_failed}
    end
  rescue
    _recovery_error -> {:error, :startup_recovery_failed}
  end

  defp reconsider_due(deferred, now, settings) do
    case deferred.reconsider_due(workflow: :dry_run, now: now, settings: settings) do
      :ok -> :ok
      {:error, _reason} -> {:error, :deferred_reconciliation_failed}
      _invalid_result -> {:error, :deferred_reconciliation_failed}
    end
  rescue
    _deferred_error -> {:error, :deferred_reconciliation_failed}
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
        {:error, :unsafe_oban_runtime}

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

  defp base_application_ready do
    if application_started?(:context_bot) and is_pid(Process.whereis(ContextBot.Repo)) do
      case {public_child_running?(), Oban.whereis(Oban)} do
        {false, nil} -> :ok
        {true, _oban_pid} -> {:error, :public_worker_running}
        {false, oban_pid} when is_pid(oban_pid) -> {:error, :unsafe_oban_runtime}
      end
    else
      {:error, :application_not_started}
    end
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  end

  defp public_child_running? do
    Enum.any?(@public_children, &(Process.whereis(&1) != nil)) or
      supervised_public_child_running?()
  end

  defp supervised_public_child_running? do
    if Process.whereis(ContextBot.Supervisor) do
      ContextBot.Supervisor
      |> Supervisor.which_children()
      |> Enum.any?(fn {id, pid, _type, _modules} -> id in @public_children and is_pid(pid) end)
    else
      false
    end
  end
end
