defmodule ContextBot.Repo.Migrations.AddRecoveryScanIndex do
  use Ecto.Migration

  def change do
    create index(:invocations, [:stage, :received_at, :id],
             name: :invocations_recovery_scan_index
           )
  end
end
