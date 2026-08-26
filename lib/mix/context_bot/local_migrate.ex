defmodule ContextBot.LocalMigrate do
  @moduledoc false

  def ensure_migrated! do
    case Mix.Task.run("ecto.migrate", ["--quiet"]) do
      :ok -> :ok
      _other -> :ok
    end
  end
end
