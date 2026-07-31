defmodule ContextBot.Repo.Migrations.AddPublicationClaimAndRepo do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :reply_repo, :text
      add :publication_claim_token, :text
      add :publication_claimed_at, :utc_datetime_usec
    end

    create index(:invocations, [:publication_claim_token])
  end
end
