defmodule ContextBot.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :context_bot

  alias ContextBot.Workflow.Reprocessor

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def reprocess(invocation_id) when is_integer(invocation_id) and invocation_id > 0 do
    load_app()

    case Application.ensure_all_started(@app) do
      {:ok, _apps} ->
        case Reprocessor.reprocess(invocation_id, now: DateTime.utc_now()) do
          {:ok, %{id: ^invocation_id}} ->
            IO.puts("status=reopened")
            IO.puts("invocation_id=#{invocation_id}")
            :ok

          {:error, reason} ->
            IO.puts("error=#{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts("startup_error=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
