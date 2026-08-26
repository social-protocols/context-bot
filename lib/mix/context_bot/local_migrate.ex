defmodule ContextBot.LocalMigrate do
  @moduledoc false

  # Shared by local Mix tasks so a stale SQLite file cannot be queried before schema is current.
  def ensure_migrated! do
    case Mix.Task.run("ecto.migrate", ["--quiet"]) do
      :ok -> :ok
      _other -> :ok
    end
  end
end
