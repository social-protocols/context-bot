defmodule ContextBot.Repo.Migrations.AddInvocationPayer do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :payer_kind, :text
      add :payer_fund_id, :text
      add :payer_handle, :text
    end
  end
end
