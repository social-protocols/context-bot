defmodule ContextBot.DryRun.Runtime do
  @moduledoc false

  alias ContextBot.DryRun.RuntimeOwner
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

  @spec try_acquire_owner(keyword()) ::
          {:ok, pid()} | {:error, :runtime_owned | :runtime_lock_failed}
  def try_acquire_owner(options \\ []) when is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)
    owner_options = Keyword.get(options, :owner_options, [])

    case owner.acquire(owner_options) do
      {:ok, owner_pid} when is_pid(owner_pid) -> {:ok, owner_pid}
      {:error, :runtime_owned} -> {:error, :runtime_owned}
      {:error, :runtime_lock_failed} -> {:error, :runtime_lock_failed}
      _invalid_result -> {:error, :runtime_lock_failed}
    end
  rescue
    _owner_error -> {:error, :runtime_lock_failed}
  catch
    :exit, _reason -> {:error, :runtime_lock_failed}
  end

  @spec start_workers(pid(), keyword()) :: :ok | {:error, atom()}
  def start_workers(owner_token, options \\ []) when is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)
    recovery = Keyword.get(options, :recovery, Recovery)
    deferred = Keyword.get(options, :deferred, DeferredWorker)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)
    base_ready = Keyword.get(options, :base_ready, &base_application_ready/0)
    settings = Application.fetch_env!(:context_bot, :settings)
    timestamp = now.()

    with :ok <- verify_owner(owner, owner_token),
         :ok <- base_ready.(),
         :ok <- recover_orphans(recovery, timestamp),
         :ok <- reconsider_due(deferred, timestamp, settings),
         :ok <- verify_owner(owner, owner_token) do
      start_minimal_oban()
    end
  end

  @spec stop(pid() | nil, keyword()) :: :ok | {:error, :worker_shutdown_failed}
  def stop(owner_token, options \\ [])

  def stop(nil, _options), do: :ok

  def stop(owner_token, options) when is_pid(owner_token) and is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)
    stop_oban = Keyword.get(options, :stop_oban, &stop_oban/0)

    case stop_oban.() do
      :ok ->
        release_owner(owner, owner_token)

      _shutdown_failure ->
        {:error, :worker_shutdown_failed}
    end
  rescue
    _shutdown_failure -> {:error, :worker_shutdown_failed}
  catch
    :exit, _reason -> {:error, :worker_shutdown_failed}
  end

  defp stop_oban do
    case Oban.whereis(Oban) do
      nil ->
        :ok

      pid ->
        if safe_owned_oban?() and not public_child_running?() do
          config = Oban.config(Oban)
          stop_owned_oban(pid, config.shutdown_grace_period + 1_000)
        else
          {:error, :worker_shutdown_failed}
        end
    end
  end

  defp stop_owned_oban(pid, timeout_ms) do
    Process.unlink(pid)
    reference = Process.monitor(pid)
    pause_owned_oban()

    try do
      Supervisor.stop(pid, :normal, timeout_ms)
    catch
      :exit, _reason ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    await_oban_down(reference, pid)
  end

  defp pause_owned_oban do
    _result = Oban.pause_all_queues(Oban)
    :ok
  rescue
    _pause_failure -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp await_oban_down(reference, pid) do
    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(reference, [:flush])
        {:error, :worker_shutdown_failed}
    end
  end

  defp verify_owner(owner, owner_token) do
    if owner.owned?(owner_token), do: :ok, else: {:error, :runtime_lock_lost}
  rescue
    _owner_error -> {:error, :runtime_lock_lost}
  catch
    :exit, _reason -> {:error, :runtime_lock_lost}
  end

  defp release_owner(owner, owner_token) do
    owner.release(owner_token)
  rescue
    _owner_error -> :ok
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
    case recovery.recover_orphans(startup?: true, workflow: :dry_run, now: now) do
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

  defp safe_owned_oban? do
    safe_oban_config?(Oban.config(Oban))
  rescue
    _missing_or_invalid_runtime -> false
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
