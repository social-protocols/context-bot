defmodule ContextBot.DryRun.RuntimeOwnerProcessTest do
  use ExUnit.Case, async: false

  @event_timeout_ms 15_000

  test "independent VMs deduplicate preparation, fence recovery, and take over after a crash" do
    root = File.cwd!()

    directory =
      Path.join(
        System.tmp_dir!(),
        "context-bot-runtime-process-#{System.unique_integer([:positive, :monotonic])}"
      )

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

    assert_eventually(Path.join(events, "first.ready"))
    assert_eventually(Path.join(events, "second.ready"))
    File.write!(gate, "go")

    assert_eventually(Path.join(events, "first.prepared"))
    assert_eventually(Path.join(events, "second.prepared"))
    assert_eventually(Path.join(events, "first.recovery"))
    assert_eventually(Path.join(events, "second.contended"))

    refute File.exists?(Path.join(events, "second.recovery"))
    refute File.exists?(Path.join(events, "second.takeover"))

    first_beam_pid = peer_os_pid(events, "first")
    assert {_, 0} = System.cmd(System.find_executable("kill"), ["-KILL", first_beam_pid])

    assert_eventually(Path.join(events, "second.takeover"))
    assert_eventually(Path.join(events, "second.recovery"))

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

  defp assert_eventually(path, attempts \\ 200)

  defp assert_eventually(path, 0), do: flunk("event did not appear: #{path}")

  defp assert_eventually(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(div(@event_timeout_ms, 200))
      assert_eventually(path, attempts - 1)
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
