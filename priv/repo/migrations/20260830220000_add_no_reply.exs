defmodule ContextBot.Repo.Migrations.AddNoReply do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :no_reply, :boolean, null: false, default: false
    end
  end
end
