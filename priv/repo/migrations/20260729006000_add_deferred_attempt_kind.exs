defmodule ContextBot.Repo.Migrations.AddDeferredAttemptKind do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :deferred_attempt_kind, :text
    end
  end
end
