defmodule ContextBot.Repo.Migrations.AddStructureKindAndCitationSources do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute "PRAGMA foreign_keys=OFF"

    rebuild_budget_entries()
    rebuild_response_envelopes()

    execute "PRAGMA foreign_keys=ON"

    alter table(:invocations) do
      add :citation_sources, {:array, :map}, default: []
    end
  end

  def down do
    alter table(:invocations) do
      remove :citation_sources
    end
  end

  defp rebuild_budget_entries do
    drop_index_if_exists("api_budget_entries_attempt_key_index")
    drop_index_if_exists("api_budget_entries_budget_date_state_index")
    drop_index_if_exists("api_budget_entries_invocation_id_index")
    drop_index_if_exists("api_budget_entries_research_claim_token_index")

    execute "ALTER TABLE api_budget_entries RENAME TO api_budget_entries_old"

    execute """
    CREATE TABLE api_budget_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      attempt_key TEXT NOT NULL,
      invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
      budget_date DATE NOT NULL,
      kind TEXT NOT NULL,
      reserved_microdollars INTEGER NOT NULL,
      settled_microdollars INTEGER,
      state TEXT NOT NULL,
      usage JSON,
      pricing_version TEXT,
      sent_at TEXT,
      response_recorded_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      research_claim_token TEXT,
      CONSTRAINT api_budget_entries_kind_check
        CHECK (kind IN ('research', 'continuation', 'repair', 'retry', 'structure')),
      CONSTRAINT api_budget_entries_reserved_nonnegative_check
        CHECK (reserved_microdollars >= 0),
      CONSTRAINT api_budget_entries_settled_range_check
        CHECK (
          settled_microdollars IS NULL OR
          (settled_microdollars >= 0 AND settled_microdollars <= reserved_microdollars)
        ),
      CONSTRAINT api_budget_entries_state_check
        CHECK (state IN ('reserved', 'sent', 'settled', 'indeterminate'))
    )
    """

    execute """
    INSERT INTO api_budget_entries (
      id, attempt_key, invocation_id, budget_date, kind, reserved_microdollars,
      settled_microdollars, state, usage, pricing_version, sent_at, response_recorded_at,
      inserted_at, updated_at, research_claim_token
    )
    SELECT
      id, attempt_key, invocation_id, budget_date, kind, reserved_microdollars,
      settled_microdollars, state, usage, pricing_version, sent_at, response_recorded_at,
      inserted_at, updated_at, research_claim_token
    FROM api_budget_entries_old
    """

    execute "DROP TABLE api_budget_entries_old"

    execute "CREATE UNIQUE INDEX api_budget_entries_attempt_key_index ON api_budget_entries (attempt_key)"

    execute "CREATE INDEX api_budget_entries_budget_date_state_index ON api_budget_entries (budget_date, state)"

    execute "CREATE INDEX api_budget_entries_invocation_id_index ON api_budget_entries (invocation_id)"

    execute "CREATE INDEX api_budget_entries_research_claim_token_index ON api_budget_entries (research_claim_token)"
  end

  defp rebuild_response_envelopes do
    drop_index_if_exists("anthropic_response_envelopes_budget_entry_id_index")
    drop_index_if_exists("anthropic_response_envelopes_attempt_key_index")
    drop_index_if_exists("anthropic_response_envelopes_invocation_id_id_index")

    execute "ALTER TABLE anthropic_response_envelopes RENAME TO anthropic_response_envelopes_old"

    execute """
    CREATE TABLE anthropic_response_envelopes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      invocation_id INTEGER NOT NULL REFERENCES invocations(id) ON DELETE CASCADE,
      budget_entry_id INTEGER REFERENCES api_budget_entries(id) ON DELETE CASCADE,
      attempt_key TEXT,
      kind TEXT,
      status INTEGER,
      metadata_blob BLOB NOT NULL,
      raw_body BLOB NOT NULL,
      received_at TEXT,
      duration_ms INTEGER,
      storage_bytes INTEGER NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CONSTRAINT anthropic_response_envelopes_kind_check
        CHECK (kind IS NULL OR kind IN ('research', 'continuation', 'repair', 'retry', 'structure'))
    )
    """

    execute """
    INSERT INTO anthropic_response_envelopes (
      id, invocation_id, budget_entry_id, attempt_key, kind, status, metadata_blob,
      raw_body, received_at, duration_ms, storage_bytes, inserted_at, updated_at
    )
    SELECT
      id, invocation_id, budget_entry_id, attempt_key, kind, status, metadata_blob,
      raw_body, received_at, duration_ms, storage_bytes, inserted_at, updated_at
    FROM anthropic_response_envelopes_old
    """

    execute "DROP TABLE anthropic_response_envelopes_old"

    execute "CREATE UNIQUE INDEX anthropic_response_envelopes_budget_entry_id_index ON anthropic_response_envelopes (budget_entry_id)"

    execute "CREATE UNIQUE INDEX anthropic_response_envelopes_attempt_key_index ON anthropic_response_envelopes (attempt_key)"

    execute "CREATE INDEX anthropic_response_envelopes_invocation_id_id_index ON anthropic_response_envelopes (invocation_id, id)"
  end

  defp drop_index_if_exists(name) do
    execute "DROP INDEX IF EXISTS #{name}"
  end
end
