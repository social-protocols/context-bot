defmodule ContextBot.Repo.Migrations.AddCanonicalMedia do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :canonical_media, :map, null: false, default: fragment("'[]'")
    end
  end
end
