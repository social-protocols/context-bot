defmodule ContextBot.Repo.Migrations.CreateAnthropicResponseEnvelopes do
  use Ecto.Migration

  @kinds ~w(research continuation repair retry)

  def change do
    alter table(:api_budget_entries) do
      add :research_claim_token, :text
    end

    create index(:api_budget_entries, [:research_claim_token])

    create table(:anthropic_response_envelopes) do
      add :invocation_id, references(:invocations, on_delete: :delete_all), null: false
      add :budget_entry_id, references(:api_budget_entries, on_delete: :delete_all)
      add :attempt_key, :text

      add :kind, :text,
        check: %{
          name: "anthropic_response_envelopes_kind_check",
          expr: "kind IS NULL OR kind IN (#{quoted_values(@kinds)})"
        }

      add :status, :integer
      add :metadata_blob, :binary, null: false
      add :raw_body, :binary, null: false
      add :received_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :storage_bytes, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:anthropic_response_envelopes, [:budget_entry_id])
    create unique_index(:anthropic_response_envelopes, [:attempt_key])
    create index(:anthropic_response_envelopes, [:invocation_id, :id])
  end

  defp quoted_values(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
