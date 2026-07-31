defmodule ContextBot.Repo.Migrations.AddResearchClaimLease do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :research_claim_token, :text
      add :research_claimed_at, :utc_datetime_usec
    end

    create index(:invocations, [:research_claim_token])
  end
end
