defmodule ContextBot.Workflow.ReprocessorRuntime do
  @moduledoc "Starts only the local SQLite dependencies required for explicit reprocessing."

  alias ContextBot.{Repo, Settings}

  @spec ensure_started(keyword()) ::
          :ok
          | {:error,
             :bot_enabled | :active_workers | :dependency_start_failed | :repo_start_failed}
  def ensure_started(options \\ []) when is_list(options) do
    settings = Keyword.get(options, :settings, Application.fetch_env!(:context_bot, :settings))

    external_workers_running? =
      Keyword.get(options, :external_workers_running?, &external_workers_running?/0)

    dependency_starter =
      Keyword.get(options, :dependency_starter, &Application.ensure_all_started/1)

    repo_running? = Keyword.get(options, :repo_running?, &repo_running?/0)
    repo_starter = Keyword.get(options, :repo_starter, &Repo.start_link/0)

    cond do
      Settings.bot_enabled?(settings) ->
        {:error, :bot_enabled}

      external_workers_running?.() ->
        {:error, :active_workers}

      true ->
        with :ok <- start_dependencies(dependency_starter),
             :ok <- start_repo(repo_running?, repo_starter),
             false <- external_workers_running?.() do
          :ok
        else
          true -> {:error, :active_workers}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _startup_error -> {:error, :repo_start_failed}
  catch
    :exit, _reason -> {:error, :repo_start_failed}
  end

  defp start_dependencies(dependency_starter) do
    case dependency_starter.(:ecto_sqlite3) do
      {:ok, _applications} -> :ok
      _failure -> {:error, :dependency_start_failed}
    end
  end

  defp start_repo(repo_running?, repo_starter) do
    if repo_running?.() do
      :ok
    else
      case repo_starter.() do
        {:ok, pid} when is_pid(pid) -> :ok
        {:error, {:already_started, pid}} when is_pid(pid) -> :ok
        _failure -> {:error, :repo_start_failed}
      end
    end
  end

  defp repo_running?, do: is_pid(Process.whereis(Repo))

  defp external_workers_running? do
    Enum.any?(
      [
        Oban.whereis(Oban),
        Process.whereis(ContextBot.ATProto.Session),
        Process.whereis(ContextBot.Mentions.Poller)
      ],
      &is_pid/1
    )
  end
end
