defmodule ContextBot.LiveRun.Runtime do
  @moduledoc false

  import Ecto.Query

  alias ContextBot.ATProto.Session
  alias ContextBot.DryRun.RuntimeOwner
  alias ContextBot.Repo
  alias ContextBot.Settings
  alias ContextBot.Workers.ResearchWorker
  alias ContextBot.Workflow.{Invocation, Recovery, Store}

  @safe_queues [:reply, :research, :thread]
  @terminal_stages [:ineligible, :complete, :failed]
  @forbidden_database_names ["context_bot_dev.db", "context_bot_test.db"]

  @spec configure_and_start(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             :application_start_failed
             | :bot_enabled
             | :migration_failed
             | :missing_configuration
             | :unsafe_database_path
             | :unsafe_runtime}
  def configure_and_start(database_path, options \\ [])

  def configure_and_start(database_path, options) when is_list(options) do
    settings = Keyword.get_lazy(options, :settings, &configured_settings/0)
    project_root = Keyword.get_lazy(options, :project_root, &File.cwd!/0)

    with :ok <- validate_configuration(settings, options),
         {:ok, database} <- safe_database_path(database_path, project_root, options),
         :ok <- File.mkdir_p(Path.dirname(database)),
         :ok <- put_bot_password(options),
         :ok <- configure_repo(database, options),
         :ok <- run_callback(options, :migrate, &migrate/0, :migration_failed),
         :ok <-
           run_callback(
             options,
             :application_start,
             &start_application/0,
             :application_start_failed
           ),
         :ok <- run_callback(options, :runtime_ready, &runtime_ready/0, :unsafe_runtime) do
      {:ok, database}
    end
  rescue
    _configuration_error -> {:error, :missing_configuration}
  end

  def configure_and_start(_database_path, _options), do: {:error, :unsafe_database_path}

  @spec try_acquire_owner(String.t(), keyword()) ::
          {:ok, pid()} | {:error, :runtime_owned | :runtime_lock_failed}
  def try_acquire_owner(database, options \\ []) when is_binary(database) and is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)

    case owner.acquire(database: database) do
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

  @spec authenticate(pid(), keyword()) :: :ok | {:error, atom()}
  def authenticate(owner_token, options \\ []) when is_pid(owner_token) and is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)
    session = Keyword.get(options, :session, Session)

    with :ok <- verify_owner(owner, owner_token),
         nil <- Process.whereis(Session),
         {:ok, session_pid} <- start_session(session),
         :ok <- authenticate_session(session, session_pid) do
      :ok
    else
      pid when is_pid(pid) -> {:error, :session_already_running}
      {:error, reason} -> {:error, reason}
      _invalid_result -> {:error, :session_unavailable}
    end
  end

  @spec start_workers(pid(), Invocation.t(), keyword()) :: :ok | {:error, atom()} | tuple()
  def start_workers(owner_token, %Invocation{} = invocation, options \\ [])
      when is_pid(owner_token) and is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)
    recovery = Keyword.get(options, :recovery, Recovery)
    base_ready = Keyword.get(options, :base_ready, &base_application_ready/0)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)
    settings = Keyword.get_lazy(options, :settings, &configured_settings/0)
    timestamp = now.()

    with :ok <- verify_owner(owner, owner_token),
         :ok <- base_ready.(),
         :ok <- ensure_only_selected_active(invocation.id),
         {:ok, current} <- resume_due_budget(invocation, timestamp),
         :ok <- recover_selected(recovery, current, timestamp, settings),
         :ok <- verify_owner(owner, owner_token),
         :ok <- ensure_only_selected_active(invocation.id) do
      start_minimal_oban()
    end
  rescue
    _runtime_error -> {:error, :worker_start_failed}
  catch
    :exit, _reason -> {:error, :worker_start_failed}
  end

  @spec stop(pid() | nil, keyword()) :: :ok | {:error, :worker_shutdown_failed}
  def stop(owner_token, options \\ [])

  def stop(nil, _options), do: :ok

  def stop(owner_token, options) when is_pid(owner_token) and is_list(options) do
    owner = Keyword.get(options, :owner, RuntimeOwner)

    with :ok <- stop_oban(),
         :ok <- stop_session() do
      release_owner(owner, owner_token)
    else
      _shutdown_failure -> {:error, :worker_shutdown_failed}
    end
  rescue
    _shutdown_failure -> {:error, :worker_shutdown_failed}
  catch
    :exit, _reason -> {:error, :worker_shutdown_failed}
  end

  @doc false
  @spec safe_oban_config?(Oban.Config.t()) :: boolean()
  def safe_oban_config?(%Oban.Config{} = config) do
    configured_queues = Enum.sort(Keyword.keys(config.queues))

    config.testing == :disabled and config.plugins == [] and
      configured_queues == @safe_queues and
      Enum.all?(config.queues, fn {_queue, options} -> options[:limit] == 1 end)
  end

  def safe_oban_config?(_config), do: false

  defp validate_configuration(%Settings{} = settings, options) do
    password = Keyword.get_lazy(options, :bot_app_password, &bot_app_password/0)

    cond do
      Settings.bot_enabled?(settings) ->
        {:error, :bot_enabled}

      not present?(settings.bot_did) or not present?(settings.bot_handle) or
        not present?(settings.bot_pds_url) or
        not (is_integer(settings.anthropic_daily_budget_microdollars) and
                 settings.anthropic_daily_budget_microdollars > 0) or not present?(password) ->
        {:error, :missing_configuration}

      true ->
        :ok
    end
  end

  defp validate_configuration(_settings, _options), do: {:error, :missing_configuration}

  defp safe_database_path(path, project_root, options)
       when is_binary(path) and is_binary(project_root) do
    if path == "" or memory_database?(path) do
      {:error, :unsafe_database_path}
    else
      expanded = Path.expand(path, project_root)
      configured = Keyword.get_lazy(options, :configured_database, &configured_database/0)
      production = Keyword.get_lazy(options, :production_database, &production_database/0)

      if forbidden_database?(expanded, project_root, configured, production) do
        {:error, :unsafe_database_path}
      else
        {:ok, expanded}
      end
    end
  end

  defp safe_database_path(_path, _project_root, _options), do: {:error, :unsafe_database_path}

  defp forbidden_database?(database, root, configured, production) do
    name = Path.basename(database)

    name in @forbidden_database_names or String.match?(name, ~r/\Acontext_bot_test_\d+\.db\z/) or
      same_path?(database, configured, root) or same_path?(database, production, root)
  end

  defp same_path?(_database, nil, _root), do: false
  defp same_path?(_database, "", _root), do: false

  defp same_path?(database, candidate, root) when is_binary(candidate),
    do: database == Path.expand(candidate, root)

  defp same_path?(_database, _candidate, _root), do: false

  defp memory_database?(database) do
    database == ":memory:" or
      (String.starts_with?(database, "file:") and String.contains?(database, "mode=memory"))
  end

  defp put_bot_password(options) do
    password = Keyword.get_lazy(options, :bot_app_password, &bot_app_password/0)
    callback = Keyword.get(options, :put_bot_password, &default_put_bot_password/1)

    normalize_callback(callback.(password), :missing_configuration)
  end

  defp configure_repo(database, options) do
    callback = Keyword.get(options, :configure_repo, &default_configure_repo/1)
    normalize_callback(callback.(database), :unsafe_runtime)
  end

  defp run_callback(options, key, default, error) do
    callback = Keyword.get(options, key, default)
    normalize_callback(callback.(), error)
  end

  defp normalize_callback(:ok, _error), do: :ok
  defp normalize_callback({:error, reason}, _error) when is_atom(reason), do: {:error, reason}
  defp normalize_callback(_invalid, error), do: {:error, error}

  defp default_put_bot_password(password) do
    Application.put_env(:context_bot, :bot_app_password, password)
    :ok
  end

  defp default_configure_repo(database) do
    config = Application.fetch_env!(:context_bot, Repo)
    Application.put_env(:context_bot, Repo, Keyword.put(config, :database, database))
    :ok
  end

  defp migrate do
    case Ecto.Migrator.with_repo(Repo, fn repo -> Ecto.Migrator.run(repo, :up, all: true) end) do
      {:ok, _migrations, _applications} -> :ok
      _failure -> {:error, :migration_failed}
    end
  end

  defp start_application do
    case Application.ensure_all_started(:context_bot) do
      {:ok, _applications} -> :ok
      {:error, _reason} -> {:error, :application_start_failed}
    end
  end

  defp runtime_ready do
    if application_started?(:context_bot) and is_pid(Process.whereis(Repo)) and
         is_nil(Oban.whereis(Oban)) and is_nil(Process.whereis(Session)) and
         is_nil(Process.whereis(ContextBot.Mentions.Poller)) do
      :ok
    else
      {:error, :unsafe_runtime}
    end
  end

  defp start_session(session) do
    case session.start_link(name: Session) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :session_already_running}
      {:error, _reason} -> {:error, :session_unavailable}
      _invalid_result -> {:error, :session_unavailable}
    end
  rescue
    _session_error -> {:error, :session_unavailable}
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp authenticate_session(session, session_pid) do
    case session.access_token() do
      {:ok, token} when is_binary(token) and token != "" -> :ok
      _authentication_failure -> stop_failed_session(session_pid)
    end
  rescue
    _authentication_failure -> stop_failed_session(session_pid)
  catch
    :exit, _reason -> stop_failed_session(session_pid)
  end

  defp stop_failed_session(session_pid) do
    _result = stop_process(session_pid)
    {:error, :session_unavailable}
  end

  defp resume_due_budget(invocation, timestamp) do
    case Store.resume_due_live_budget(invocation, timestamp, &research_job/2) do
      {:ok, current, _disposition} -> {:ok, current}
      {:error, _reason} -> {:error, :budget_resume_failed}
    end
  end

  defp research_job(uri, cid) do
    Oban.Job.new(%{"uri" => uri, "cid" => cid},
      worker: ResearchWorker,
      queue: :research,
      unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]
    )
  end

  defp recover_selected(recovery, invocation, timestamp, settings) do
    case recovery.recover_invocation(invocation,
           startup?: true,
           now: timestamp,
           settings: settings
         ) do
      result when result in [:resumed, :terminalized, :unchanged] -> :ok
      _invalid_result -> {:error, :startup_recovery_failed}
    end
  rescue
    _recovery_error -> {:error, :startup_recovery_failed}
  end

  defp ensure_only_selected_active(selected_id) do
    active =
      Invocation
      |> where([invocation], invocation.id != ^selected_id)
      |> where([invocation], invocation.stage not in ^@terminal_stages)
      |> order_by([invocation], asc: invocation.received_at, asc: invocation.id)
      |> limit(1)
      |> Repo.one()

    if active do
      {:error, :active_invocation, %{id: active.id, uri: active.invocation_uri}}
    else
      :ok
    end
  end

  defp start_minimal_oban do
    options =
      :context_bot
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:queues, thread: 1, research: 1, reply: 1)
      |> Keyword.put(:plugins, [])
      |> Keyword.delete(:testing)

    case Oban.start_link(options) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :unsafe_oban_runtime}
      {:error, _reason} -> {:error, :oban_start_failed}
    end
  end

  defp stop_oban do
    case Oban.whereis(Oban) do
      nil ->
        :ok

      pid ->
        if safe_owned_oban?() do
          config = Oban.config(Oban)
          _result = pause_owned_oban()
          stop_process(pid, config.shutdown_grace_period + 1_000)
        else
          {:error, :worker_shutdown_failed}
        end
    end
  end

  defp stop_session do
    case Process.whereis(Session) do
      nil -> :ok
      pid -> stop_process(pid)
    end
  end

  defp stop_process(pid, timeout_ms \\ 2_000) do
    Process.unlink(pid)
    reference = Process.monitor(pid)

    try do
      Supervisor.stop(pid, :normal, timeout_ms)
    catch
      :exit, _reason -> if Process.alive?(pid), do: Process.exit(pid, :kill)
    end

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(reference, [:flush])
        {:error, :worker_shutdown_failed}
    end
  end

  defp pause_owned_oban do
    Oban.pause_all_queues(Oban)
  rescue
    _pause_failure -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp safe_owned_oban? do
    safe_oban_config?(Oban.config(Oban))
  rescue
    _missing_runtime -> false
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

  defp base_application_ready do
    if application_started?(:context_bot) and is_pid(Process.whereis(Repo)) and
         is_pid(Process.whereis(Session)) and is_nil(Process.whereis(ContextBot.Mentions.Poller)) and
         is_nil(Oban.whereis(Oban)) do
      :ok
    else
      {:error, :unsafe_runtime}
    end
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  end

  defp configured_settings, do: Application.fetch_env!(:context_bot, :settings)

  defp configured_database do
    :context_bot
    |> Application.fetch_env!(Repo)
    |> Keyword.fetch!(:database)
  end

  defp production_database, do: System.get_env("DATABASE_PATH")
  defp bot_app_password, do: System.get_env("BOT_APP_PASSWORD")
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
