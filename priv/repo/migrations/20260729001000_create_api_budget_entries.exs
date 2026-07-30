defmodule ContextBot.Repo.Migrations.CreateApiBudgetEntries do
  use Ecto.Migration

  @kinds ~w(research continuation repair retry)
  @states ~w(reserved sent settled indeterminate)

  def change do
    create table(:api_budget_entries) do
      add :attempt_key, :text, null: false
      add :invocation_id, references(:invocations, on_delete: :delete_all), null: false
      add :budget_date, :date, null: false

      add :kind, :text,
        null: false,
        check: %{
          name: "api_budget_entries_kind_check",
          expr: "kind IN (#{quoted_values(@kinds)})"
        }

      add :reserved_microdollars, :integer,
        null: false,
        check: %{
          name: "api_budget_entries_reserved_nonnegative_check",
          expr: "reserved_microdollars >= 0"
        }

      add :settled_microdollars, :integer,
        check: %{
          name: "api_budget_entries_settled_range_check",
          expr:
            "settled_microdollars IS NULL OR " <>
              "(settled_microdollars >= 0 AND settled_microdollars <= reserved_microdollars)"
        }

      add :state, :text,
        null: false,
        check: %{
          name: "api_budget_entries_state_check",
          expr: "state IN (#{quoted_values(@states)})"
        }

      add :usage, :map
      add :pricing_version, :text
      add :sent_at, :utc_datetime_usec
      add :response_recorded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_budget_entries, [:attempt_key])
    create index(:api_budget_entries, [:budget_date, :state])
    create index(:api_budget_entries, [:invocation_id])
  end

  defp quoted_values(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
