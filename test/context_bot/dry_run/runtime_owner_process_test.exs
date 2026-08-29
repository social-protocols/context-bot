defmodule ContextBot.DryRun.RuntimeOwnerProcessTest do
  use ExUnit.Case, async: false

  @event_timeout_ms 25_000

  test "isolates the runtime directory per OS process" do
    first = runtime_process_directory(1_001)
    second = runtime_process_directory(2_002)

    assert first != second
    assert Path.basename(first) =~ "-1001-"
    assert Path.basename(second) =~ "-2002-"
  end

  test "independent VMs deduplicate preparation, fence recovery, and take over after a crash" do
    root = File.cwd!()
    directory = runtime_process_directory()

    database = Path.join(directory, "context_bot.db")
    events = Path.join(directory, "events")
    gate = Path.join(directory, "start")
    helper = Path.join(root, "test/support/cross_process_runtime_peer.exs")

    File.mkdir_p!(events)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert {_, 0} = run_helper(helper, ["setup", database])

    first = start_peer(helper, "first", database, events, gate)
    second = start_peer(helper, "second", database, events, gate)

    on_exit(fn ->
      stop_peer(first)
      stop_peer(second)
    end)

    peers = [first, second]
    assert_eventually(Path.join(events, "first.ready"), peers)
    assert_eventually(Path.join(events, "second.ready"), peers)
    File.write!(gate, "go")

    assert_eventually(Path.join(events, "first.prepared"), peers)
    assert_eventually(Path.join(events, "second.prepared"), peers)
    assert_eventually(Path.join(events, "first.recovery"), peers)
    assert_eventually(Path.join(events, "second.contended"), peers)

    refute File.exists?(Path.join(events, "second.recovery"))
    refute File.exists?(Path.join(events, "second.takeover"))

    first_beam_pid = peer_os_pid(events, "first")
    assert {_, 0} = System.cmd(System.find_executable("kill"), ["-KILL", first_beam_pid])

    assert_eventually(Path.join(events, "second.takeover"), peers)
    assert_eventually(Path.join(events, "second.recovery"), peers)

    assert {first_output, first_status} = await_exit(first.port)
    assert first_status != 0, first_output
    assert {second_output, 0} = await_exit(second.port)

    prepared =
      for role <- ["first", "second"] do
        [id, disposition] =
          events
          |> Path.join("#{role}.prepared")
          |> File.read!()
          |> String.trim()
          |> String.split(":", parts: 2)

        {id, disposition}
      end

    assert prepared |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1
    assert prepared |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["attached", "created"]

    assert sqlite_scalar(database, "SELECT COUNT(*) FROM invocations") == "1"
    assert sqlite_scalar(database, "SELECT COUNT(*) FROM oban_jobs") == "1"

    assert second_output =~ "runtime_takeover_complete"
  end

  defp run_helper(helper, arguments) do
    System.cmd(
      System.find_executable("mix"),
      ["run", "--no-start", "--no-compile", "--no-deps-check", helper, "--" | arguments],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp start_peer(helper, role, database, events, gate) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "run",
            "--no-start",
            "--no-compile",
            "--no-deps-check",
            helper,
            "--",
            "peer",
            role,
            database,
            events,
            gate
          ],
          env: [{~c"MIX_ENV", ~c"test"}]
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    %{port: port, os_pid: os_pid, role: role, events: events}
  end

  defp stop_peer(%{port: port, os_pid: os_pid, role: role, events: events}) do
    if Port.info(port) do
      beam_pid = peer_os_pid(events, role, fallback: os_pid)
      _result = System.cmd(System.find_executable("kill"), ["-KILL", beam_pid])
      _result = System.cmd(System.find_executable("kill"), ["-KILL", to_string(os_pid)])
      _result = await_exit(port)
    end

    :ok
  end

  defp await_exit(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      @event_timeout_ms -> flunk("peer did not exit; output=#{inspect(output)}")
    end
  end

  defp runtime_process_directory(os_pid \\ :os.getpid()) do
    Path.join(
      System.tmp_dir!(),
      "context-bot-runtime-process-#{os_pid}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    )
  end

  defp assert_eventually(path, peers, attempts \\ 250)

  defp assert_eventually(path, peers, 0) do
    flunk(event_timeout_message(path, peers))
  end

  defp assert_eventually(path, peers, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(div(@event_timeout_ms, 250))
      assert_eventually(path, peers, attempts - 1)
    end
  end

  defp event_timeout_message(path, peers) do
    events_dir = Path.dirname(path)

    seen =
      case File.ls(events_dir) do
        {:ok, names} -> Enum.sort(names)
        {:error, reason} -> [":ls_failed #{inspect(reason)}"]
      end

    snapshots = Enum.map_join(peers, "\n", &peer_output_snapshot/1)
    "event did not appear: #{path}; seen=#{inspect(seen)}\n#{snapshots}"
  end

  defp peer_output_snapshot(%{port: port, role: role}) do
    "#{role} output=#{inspect(drain_port_data(port))}"
  end

  defp drain_port_data(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> drain_port_data(port, output <> data)
    after
      0 -> output
    end
  end

  defp peer_os_pid(events, role, opts \\ []) do
    fallback = Keyword.get(opts, :fallback)

    case File.read(Path.join(events, "#{role}.os_pid")) do
      {:ok, contents} ->
        pid = String.trim(contents)
        if pid != "", do: pid, else: fallback && to_string(fallback)

      {:error, _reason} ->
        fallback && to_string(fallback)
    end
  end

  defp sqlite_scalar(database, query) do
    assert {output, 0} =
             System.cmd(System.find_executable("sqlite3"), [
               "-batch",
               "-noheader",
               database,
               query
             ])

    String.trim(output)
  end
end
