defmodule ContextBot.Workflow.ReprocessorRuntimeTest do
  use ExUnit.Case, async: true

  alias ContextBot.Settings
  alias ContextBot.Workflow.ReprocessorRuntime

  test "starts only SQLite dependencies and the Repo in a worker-free runtime" do
    test_pid = self()

    assert :ok =
             ReprocessorRuntime.ensure_started(
               settings: Settings.load(bot_enabled: false),
               external_workers_running?: fn -> false end,
               dependency_starter: fn application ->
                 send(test_pid, {:dependency_started, application})
                 {:ok, [application]}
               end,
               repo_running?: fn -> false end,
               repo_starter: fn ->
                 send(test_pid, :repo_started)
                 {:ok, self()}
               end
             )

    assert_received {:dependency_started, :ecto_sqlite3}
    assert_received :repo_started
    refute_received {:dependency_started, :context_bot}
  end

  test "rejects enabled bot configuration before starting dependencies" do
    test_pid = self()
    settings = %{Settings.load(bot_enabled: false) | bot_enabled: true}

    assert {:error, :bot_enabled} =
             ReprocessorRuntime.ensure_started(
               settings: settings,
               external_workers_running?: fn -> false end,
               dependency_starter: fn application ->
                 send(test_pid, {:dependency_started, application})
                 {:ok, [application]}
               end
             )

    refute_received {:dependency_started, _application}
  end

  test "rejects an active worker runtime before mutating state" do
    test_pid = self()

    assert {:error, :active_workers} =
             ReprocessorRuntime.ensure_started(
               settings: Settings.load(bot_enabled: false),
               external_workers_running?: fn -> true end,
               dependency_starter: fn application ->
                 send(test_pid, {:dependency_started, application})
                 {:ok, [application]}
               end
             )

    refute_received {:dependency_started, _application}
  end

  test "treats a missing Oban registry as a worker-free runtime" do
    refute ReprocessorRuntime.oban_running?(
             fn Oban.Registry -> nil end,
             fn _name -> flunk("Oban lookup must not run without its registry") end
           )

    assert ReprocessorRuntime.oban_running?(
             fn Oban.Registry -> self() end,
             fn Oban -> raise "unexpected lookup failure" end
           )
  end

  test "reuses an existing Repo and normalizes dependency and Repo failures" do
    settings = Settings.load(bot_enabled: false)

    assert :ok =
             ReprocessorRuntime.ensure_started(
               settings: settings,
               external_workers_running?: fn -> false end,
               dependency_starter: fn :ecto_sqlite3 -> {:ok, [:ecto_sqlite3]} end,
               repo_running?: fn -> true end,
               repo_starter: fn -> flunk("existing Repo must not be restarted") end
             )

    assert {:error, :dependency_start_failed} =
             ReprocessorRuntime.ensure_started(
               settings: settings,
               external_workers_running?: fn -> false end,
               dependency_starter: fn :ecto_sqlite3 -> {:error, :private_reason} end
             )

    assert {:error, :repo_start_failed} =
             ReprocessorRuntime.ensure_started(
               settings: settings,
               external_workers_running?: fn -> false end,
               dependency_starter: fn :ecto_sqlite3 -> {:ok, [:ecto_sqlite3]} end,
               repo_running?: fn -> false end,
               repo_starter: fn -> {:error, :private_reason} end
             )
  end
end
