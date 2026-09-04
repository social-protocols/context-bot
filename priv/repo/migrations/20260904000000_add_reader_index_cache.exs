defmodule ContextBot.Repo.Migrations.AddReaderIndexCache do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :reader_ready_at, :utc_datetime_usec
      add :reader_checked_at, :utc_datetime_usec
    end
  end
end
