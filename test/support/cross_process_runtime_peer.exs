defmodule ContextBot.Test.CrossProcessRuntimePeer do
  alias ContextBot.DryRun.RuntimeOwner
  alias ContextBot.Repo
  alias ContextBot.Workflow.Store
  alias Ecto.Migrator

  @target_uri "at://did:plc:target/app.bsky.feed.post/cross-process-owner"
  @question "What is the shared context?"
  @received_at ~U[2026-08-10 12:00:00.000000Z]
  @wait_attempts 2_500

  def run(["setup", database]) do
    repo = start_repo!(database)
    migrations = Application.app_dir(:context_bot, "priv/repo/migrations")
    _versions = Migrator.run(Repo, migrations, :up, all: true)
    GenServer.stop(repo)
  end

  def run(["peer", role, database, events, gate]) when role in ["first", "second"] do
    write_event(events, role, "os_pid", to_string(:os.getpid()))
    _repo = start_repo!(database)
    write_event(events, role, "ready", "ready")
    wait_for!(gate)

    {:ok, invocation, disposition} =
      Store.create_or_attach_dry_run(
        @target_uri,
        @question,
        @received_at,
        &thread_job/2
      )

    write_event(events, role, "prepared", "#{invocation.id}:#{disposition}")
    own_runtime(role, database, events)
  end

  defp own_runtime("first", database, events) do
    wait_for!(Path.join(events, "second.prepared"))
    {:ok, _owner} = RuntimeOwner.acquire(database: database)
    write_event(events, "first", "owner", "acquired")
    write_event(events, "first", "recovery", "started")
    Process.sleep(:infinity)
  end

  defp own_runtime("second", database, events) do
    wait_for!(Path.join(events, "first.recovery"))
    await_contention!(database, events)
    write_event(events, "second", "contended", "owner-active")
    owner = acquire_eventually!(database)
    write_event(events, "second", "takeover", "acquired")
    write_event(events, "second", "recovery", "started")
    :ok = RuntimeOwner.release(owner)
    IO.puts("runtime_takeover_complete")
  end

  defp start_repo!(database) do
    _loaded = Application.load(:context_bot)

    Application.put_env(:context_bot, Repo,
      database: database,
      pool: DBConnection.ConnectionPool,
      pool_size: 1,
      journal_mode: :wal,
      busy_timeout: 5_000,
      log: false
    )

    {:ok, _applications} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, repo} = Repo.start_link()
    repo
  end

  defp thread_job(uri, cid) do
    Oban.Job.new(
      %{"uri" => uri, "cid" => cid},
      worker: "ContextBot.Workers.ThreadWorker",
      queue: :dry_thread
    )
  end

  defp await_contention!(database, events, attempts \\ 100)

  defp await_contention!(_database, events, 0) do
    write_event(events, "second", "acquire_failed", "no-runtime-owned")
    raise "expected runtime_owned while first held the lock"
  end

  defp await_contention!(database, events, attempts) do
    case RuntimeOwner.acquire(database: database, handshake_timeout_ms: 200) do
      {:error, :runtime_owned} ->
        :ok

      {:error, :runtime_lock_failed} ->
        Process.sleep(10)
        await_contention!(database, events, attempts - 1)

      {:ok, owner} ->
        write_event(events, "second", "acquire_unexpected", "lock-free")
        _released = RuntimeOwner.release(owner)
        raise "lock was free while first should have held it"
    end
  end

  defp acquire_eventually!(database, attempts \\ @wait_attempts)

  defp acquire_eventually!(_database, 0), do: raise("runtime takeover timed out")

  defp acquire_eventually!(database, attempts) do
    case RuntimeOwner.acquire(database: database, handshake_timeout_ms: 200) do
      {:ok, owner} ->
        owner

      {:error, reason} when reason in [:runtime_owned, :runtime_lock_failed] ->
        Process.sleep(10)
        acquire_eventually!(database, attempts - 1)
    end
  end

  defp wait_for!(path, attempts \\ @wait_attempts)

  defp wait_for!(path, 0), do: raise("timed out waiting for #{Path.basename(path)}")

  defp wait_for!(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      wait_for!(path, attempts - 1)
    end
  end

  defp write_event(directory, role, name, contents) do
    File.write!(Path.join(directory, "#{role}.#{name}"), contents)
  end
end

arguments =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

ContextBot.Test.CrossProcessRuntimePeer.run(arguments)
