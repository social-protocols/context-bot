defmodule ContextBot.DryRun.RuntimeOwnerTest do
  use ExUnit.Case, async: true

  alias ContextBot.DryRun.RuntimeOwner

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "context-bot-runtime-owner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory: directory}
  end

  test "derives one persistent lock path from the absolute SQLite database path", %{
    directory: dir
  } do
    database = Path.join(dir, "context_bot.db")

    assert RuntimeOwner.lock_path(database) ==
             Path.expand(database) <> ".dry-run-runtime.lock"

    assert {:error, :runtime_lock_failed} = RuntimeOwner.lock_path(":memory:")
    assert {:error, :runtime_lock_failed} = RuntimeOwner.lock_path("")
  end

  test "only one owner acquires a database lock and explicit release permits takeover", %{
    directory: dir
  } do
    database = Path.join(dir, "shared.db")

    assert {:ok, owner} = RuntimeOwner.acquire(database: database)
    assert RuntimeOwner.owned?(owner)
    assert {:error, :runtime_owned} = RuntimeOwner.acquire(database: database)

    assert {:error, :runtime_owned} =
             RuntimeOwner.acquire(database: database, pause_after_open_ms: 20)

    assert :ok = RuntimeOwner.release(owner)
    refute Process.alive?(owner)

    assert {:ok, successor} = RuntimeOwner.acquire(database: database)
    assert RuntimeOwner.owned?(successor)
    assert :ok = RuntimeOwner.release(successor)
  end

  test "an owner process crash closes the Port and releases the OS lock", %{directory: dir} do
    database = Path.join(dir, "crash.db")
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    assert {:ok, owner} = RuntimeOwner.acquire(database: database)
    reference = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^reference, :process, ^owner, :killed}
    assert_receive {:EXIT, ^owner, :killed}

    assert {:ok, successor} = acquire_eventually(database)
    assert :ok = RuntimeOwner.release(successor)
  end

  test "different configured databases never contend", %{directory: dir} do
    assert {:ok, first} = RuntimeOwner.acquire(database: Path.join(dir, "first.db"))
    assert {:ok, second} = RuntimeOwner.acquire(database: Path.join(dir, "second.db"))

    assert :ok = RuntimeOwner.release(first)
    assert :ok = RuntimeOwner.release(second)
  end

  test "a flock that exits 75 before the handshake Port.command is runtime_owned", %{
    directory: dir
  } do
    flock = conflict_flock_stub(dir)
    database = Path.join(dir, "closed-conflict.db")

    assert {:error, :runtime_owned} =
             RuntimeOwner.acquire(
               database: database,
               flock: flock,
               handshake_timeout_ms: 500,
               pause_after_open_ms: 20
             )
  end

  test "a flock that exits a non-conflict status before handshake stays lock-failed", %{
    directory: dir
  } do
    flock = failing_flock_stub(dir, status: 1)
    database = Path.join(dir, "closed-failure.db")

    assert {:error, :runtime_lock_failed} =
             RuntimeOwner.acquire(
               database: database,
               flock: flock,
               handshake_timeout_ms: 500,
               pause_after_open_ms: 20
             )
  end

  defp acquire_eventually(database, attempts \\ 20)

  defp acquire_eventually(_database, 0), do: {:error, :runtime_lock_failed}

  defp acquire_eventually(database, attempts) do
    case RuntimeOwner.acquire(database: database) do
      {:error, :runtime_owned} ->
        Process.sleep(10)
        acquire_eventually(database, attempts - 1)

      result ->
        result
    end
  end

  defp conflict_flock_stub(directory) do
    write_stub(directory, "flock-conflict", """
    #!/bin/sh
    exit 75
    """)
  end

  defp failing_flock_stub(directory, opts) do
    write_stub(directory, "flock-failed", """
    #!/bin/sh
    exit #{Keyword.fetch!(opts, :status)}
    """)
  end

  defp write_stub(directory, name, script) do
    path = Path.join(directory, name)
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
