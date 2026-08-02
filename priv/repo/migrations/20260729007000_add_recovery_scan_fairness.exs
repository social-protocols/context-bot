defmodule ContextBot.Repo.Migrations.AddRecoveryScanFairness do
  use Ecto.Migration

  def change do
    alter table(:invocations) do
      add :recovery_checked_at, :utc_datetime_usec
    end

    drop_if_exists index(:invocations, [:stage, :received_at, :id],
                     name: :invocations_recovery_scan_index
                   )

    create index(:invocations, [:recovery_checked_at, :received_at, :id],
             name: :invocations_recovery_scan_index,
             where:
               "stage IN ('received', 'checking_eligibility', 'capturing_thread', " <>
                 "'thread_ready', 'researching', 'reply_ready', 'publishing')"
           )
  end
end
