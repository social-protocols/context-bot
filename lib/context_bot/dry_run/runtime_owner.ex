defmodule ContextBot.DryRun.RuntimeOwner do
  @moduledoc false

  use GenServer

  @conflict_exit_status 75
  @default_handshake_timeout_ms 2_000
  @maximum_handshake_bytes 256
  @lock_suffix ".dry-run-runtime.lock"

  @spec acquire(keyword()) ::
          {:ok, pid()} | {:error, :runtime_owned | :runtime_lock_failed}
  def acquire(options \\ []) when is_list(options) do
    database = Keyword.get_lazy(options, :database, &configured_database/0)
    flock = Keyword.get_lazy(options, :flock, &find_flock/0)
    cat = Keyword.get_lazy(options, :cat, &find_cat/0)
    timeout_ms = Keyword.get(options, :handshake_timeout_ms, @default_handshake_timeout_ms)
    # Test-only: delay after Port.open so flock can exit before Port.command.
    pause_ms = Keyword.get(options, :pause_after_open_ms, 0)

    with lock_path when is_binary(lock_path) <- lock_path(database),
         flock when is_binary(flock) <- flock,
         cat when is_binary(cat) <- cat,
         true <- is_integer(timeout_ms) and timeout_ms > 0,
         true <- is_integer(pause_ms) and pause_ms >= 0 do
      case GenServer.start(__MODULE__, {self(), flock, cat, lock_path, timeout_ms, pause_ms}) do
        {:ok, owner} ->
          Process.link(owner)
          {:ok, owner}

        {:error, :runtime_owned} ->
          {:error, :runtime_owned}

        {:error, _reason} ->
          {:error, :runtime_lock_failed}
      end
    else
      _invalid_lock_configuration -> {:error, :runtime_lock_failed}
    end
  rescue
    _invalid_lock_configuration -> {:error, :runtime_lock_failed}
  catch
    :exit, _reason -> {:error, :runtime_lock_failed}
  end

  @spec release(pid()) :: :ok
  def release(owner) when is_pid(owner) do
    if Process.alive?(owner), do: GenServer.stop(owner, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec owned?(pid()) :: boolean()
  def owned?(owner) when is_pid(owner) do
    GenServer.call(owner, :owned?) == true
  catch
    :exit, _reason -> false
  end

  def owned?(_owner), do: false

  @spec lock_path(String.t()) :: String.t() | {:error, :runtime_lock_failed}
  def lock_path(database) when is_binary(database) and database != "" do
    if memory_database?(database) do
      {:error, :runtime_lock_failed}
    else
      Path.expand(database) <> @lock_suffix
    end
  end

  def lock_path(_database), do: {:error, :runtime_lock_failed}

  @impl GenServer
  def init({caller, flock, cat, lock_path, timeout_ms, pause_ms}) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    case open_lock_port(flock, cat, lock_path, timeout_ms, pause_ms) do
      {:ok, port} -> {:ok, %{caller_monitor: caller_monitor, port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:owned?, _from, state), do: {:reply, true, state}

  @impl GenServer
  def handle_info({port, {:data, _unexpected}}, %{port: port} = state),
    do: {:stop, :runtime_lock_protocol_failed, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:runtime_lock_process_exited, status}, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:stop, {:runtime_lock_process_exited, reason}, state}

  def handle_info(
        {:DOWN, reference, :process, _caller, _reason},
        %{caller_monitor: reference} = state
      ),
      do: {:stop, :runtime_owner_exited, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) do
    close_port(port)
  end

  defp open_lock_port(flock, cat, lock_path, timeout_ms, pause_ms) do
    port =
      Port.open(
        {:spawn_executable, flock},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [
            "-x",
            "-n",
            "-o",
            "-E",
            Integer.to_string(@conflict_exit_status),
            lock_path,
            cat
          ]
        ]
      )

    if pause_ms > 0, do: Process.sleep(pause_ms)

    nonce = "context-bot-owner-#{System.unique_integer([:positive, :monotonic])}\n"

    case write_handshake(port, nonce) do
      :ok ->
        finish_handshake(port, nonce, timeout_ms)

      :closed ->
        classify_closed_port(port, timeout_ms)
    end
  rescue
    _port_error -> {:error, :runtime_lock_failed}
  end

  defp write_handshake(port, nonce) do
    case Port.command(port, nonce) do
      true -> :ok
      false -> :ok
    end
  rescue
    ArgumentError -> :closed
  end

  defp finish_handshake(port, nonce, timeout_ms) do
    case await_handshake(port, nonce, <<>>, timeout_ms) do
      :ok ->
        {:ok, port}

      {:error, reason} ->
        close_port(port)
        {:error, reason}
    end
  end

  defp await_handshake(port, nonce, buffer, timeout_ms) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        received = buffer <> data

        cond do
          received == nonce ->
            :ok

          byte_size(received) > @maximum_handshake_bytes ->
            {:error, :runtime_lock_failed}

          String.starts_with?(nonce, received) ->
            await_handshake(port, nonce, received, timeout_ms)

          true ->
            {:error, :runtime_lock_failed}
        end

      {^port, {:exit_status, status}} ->
        classify_exit_status(status)

      {:EXIT, ^port, _reason} ->
        # The linked EXIT can beat {:exit_status, 75}. Keep waiting for the status.
        await_handshake(port, nonce, buffer, timeout_ms)
    after
      timeout_ms -> {:error, :runtime_lock_failed}
    end
  end

  defp classify_closed_port(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} ->
        drain_port_exit(port)
        classify_exit_status(status)

      {:EXIT, ^port, _reason} ->
        classify_closed_port(port, timeout_ms)

      {^port, {:data, _data}} ->
        classify_closed_port(port, timeout_ms)
    after
      timeout_ms -> {:error, :runtime_lock_failed}
    end
  end

  defp classify_exit_status(@conflict_exit_status), do: {:error, :runtime_owned}
  defp classify_exit_status(_status), do: {:error, :runtime_lock_failed}

  defp drain_port_exit(port) do
    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _already_closed -> :ok
  end

  defp configured_database do
    :context_bot
    |> Application.fetch_env!(ContextBot.Repo)
    |> Keyword.fetch!(:database)
  end

  defp find_flock, do: System.find_executable("flock")
  defp find_cat, do: System.find_executable("cat")

  defp memory_database?(database) do
    database == ":memory:" or
      (String.starts_with?(database, "file:") and String.contains?(database, "mode=memory"))
  end
end
