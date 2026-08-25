defmodule ContextBot.Repo.Migrations.AddContainsVideo do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :contains_video, :boolean, default: false, null: false
    end
  end
end
