defmodule ContextBot.Repo.Migrations.AddInvalidRepairFailureCategory do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute "PRAGMA foreign_keys=OFF"

    rebuild_invocations()
    # SQLite retargets child REFERENCES to invocations_old on rename. Recreate
    # those tables so they point at the rebuilt invocations parent.
    rebuild_budget_entries()
    rebuild_response_envelopes()

    execute "PRAGMA foreign_keys=ON"
  end

  def down do
    execute "PRAGMA foreign_keys=OFF"

    rebuild_invocations(include_invalid_repair?: false)
    rebuild_budget_entries()
    rebuild_response_envelopes()

    execute "PRAGMA foreign_keys=ON"
  end

  defp rebuild_invocations(opts \\ []) do
    include_invalid_repair? = Keyword.get(opts, :include_invalid_repair?, true)

    drop_index_if_exists("invocations_invocation_uri_notification_cid_index")
    drop_index_if_exists("invocations_reply_rkey_index")
    drop_index_if_exists("invocations_status_index")
    drop_index_if_exists("invocations_defer_until_index")
    drop_index_if_exists("invocations_actor_did_index")
    drop_index_if_exists("invocations_admitted_at_index")
    drop_index_if_exists("invocations_research_claim_token_index")
    drop_index_if_exists("invocations_publication_claim_token_index")
    drop_index_if_exists("invocations_recovery_scan_index")

    execute "ALTER TABLE invocations RENAME TO invocations_old"

    execute """
    CREATE TABLE invocations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      invocation_uri TEXT NOT NULL,
      notification_cid TEXT NOT NULL,
      current_cid TEXT NOT NULL,
      actor_did TEXT NOT NULL,
      actor_handle TEXT,
      raw_notification TEXT NOT NULL,
      received_at TEXT NOT NULL,
      status TEXT NOT NULL
        CONSTRAINT invocations_status_check
        CHECK (status IN (
          'received', 'deferred_capacity', 'checking_eligibility', 'ineligible',
          'deferred_rate', 'capturing_thread', 'thread_ready', 'deferred_budget',
          'researching', 'reply_ready', 'publishing', 'complete', 'failed'
        )),
      stage TEXT NOT NULL
        CONSTRAINT invocations_stage_check
        CHECK (stage IN (
          'received', 'deferred_capacity', 'checking_eligibility', 'ineligible',
          'deferred_rate', 'capturing_thread', 'thread_ready', 'deferred_budget',
          'researching', 'reply_ready', 'publishing', 'complete', 'failed'
        )),
      eligibility_method TEXT,
      eligibility_evidence TEXT,
      admitted_at TEXT,
      defer_until TEXT,
      raw_thread TEXT,
      canonical_thread TEXT,
      canonical_thread_version TEXT,
      root_uri TEXT,
      root_cid TEXT,
      anthropic_messages TEXT,
      anthropic_responses TEXT DEFAULT '[]' NOT NULL,
      anthropic_attempt_sequence INTEGER DEFAULT 0 NOT NULL,
      anthropic_usage TEXT,
      selected_reply TEXT,
      reply_validation TEXT,
      reply_rkey TEXT,
      reply_record TEXT,
      reply_uri TEXT,
      reply_cid TEXT,
      failure_category TEXT
        CONSTRAINT invocations_failure_category_check
        CHECK (failure_category IS NULL OR failure_category IN (#{failure_category_values(include_invalid_repair?)})),
      failure_detail TEXT,
      completed_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      research_claim_token TEXT,
      research_claimed_at TEXT,
      reply_repo TEXT,
      publication_claim_token TEXT,
      publication_claimed_at TEXT,
      deferred_attempt_kind TEXT,
      recovery_checked_at TEXT,
      target_uri TEXT,
      invocation_text TEXT,
      dry_run INTEGER DEFAULT false NOT NULL
        CONSTRAINT dry_run_input_check
        CHECK (
          dry_run = 0 OR (
            target_uri IS NOT NULL AND length(target_uri) > 0 AND
            invocation_text IS NOT NULL AND length(invocation_text) > 0
          )
        ),
      canonical_media TEXT DEFAULT '[]' NOT NULL,
      reply_part2_rkey TEXT,
      reply_part2_record TEXT,
      reply_part2_uri TEXT,
      reply_part2_cid TEXT,
      full_response TEXT,
      standard_site_document_uri TEXT,
      standard_site_document_rkey TEXT,
      contains_video INTEGER DEFAULT false NOT NULL,
      reply_part3_rkey TEXT,
      reply_part3_record TEXT,
      reply_part3_uri TEXT,
      reply_part3_cid TEXT,
      limit_notice_kind TEXT,
      limit_notice_uri TEXT,
      limit_notice_cid TEXT,
      limit_notice_posted_at TEXT,
      no_reply INTEGER DEFAULT false NOT NULL,
      citation_sources TEXT DEFAULT ('[]')
    )
    """

    execute """
    INSERT INTO invocations (
      id, invocation_uri, notification_cid, current_cid, actor_did, actor_handle,
      raw_notification, received_at, status, stage, eligibility_method, eligibility_evidence,
      admitted_at, defer_until, raw_thread, canonical_thread, canonical_thread_version,
      root_uri, root_cid, anthropic_messages, anthropic_responses, anthropic_attempt_sequence,
      anthropic_usage, selected_reply, reply_validation, reply_rkey, reply_record,
      reply_uri, reply_cid, failure_category, failure_detail, completed_at, inserted_at,
      updated_at, research_claim_token, research_claimed_at, reply_repo,
      publication_claim_token, publication_claimed_at, deferred_attempt_kind,
      recovery_checked_at, target_uri, invocation_text, dry_run, canonical_media,
      reply_part2_rkey, reply_part2_record, reply_part2_uri, reply_part2_cid,
      full_response, standard_site_document_uri, standard_site_document_rkey,
      contains_video, reply_part3_rkey, reply_part3_record, reply_part3_uri,
      reply_part3_cid, limit_notice_kind, limit_notice_uri, limit_notice_cid,
      limit_notice_posted_at, no_reply, citation_sources
    )
    SELECT
      id, invocation_uri, notification_cid, current_cid, actor_did, actor_handle,
      raw_notification, received_at, status, stage, eligibility_method, eligibility_evidence,
      admitted_at, defer_until, raw_thread, canonical_thread, canonical_thread_version,
      root_uri, root_cid, anthropic_messages, anthropic_responses, anthropic_attempt_sequence,
      anthropic_usage, selected_reply, reply_validation, reply_rkey, reply_record,
      reply_uri, reply_cid, failure_category, failure_detail, completed_at, inserted_at,
      updated_at, research_claim_token, research_claimed_at, reply_repo,
      publication_claim_token, publication_claimed_at, deferred_attempt_kind,
      recovery_checked_at, target_uri, invocation_text, dry_run, canonical_media,
      reply_part2_rkey, reply_part2_record, reply_part2_uri, reply_part2_cid,
      full_response, standard_site_document_uri, standard_site_document_rkey,
      contains_video, reply_part3_rkey, reply_part3_record, reply_part3_uri,
      reply_part3_cid, limit_notice_kind, limit_notice_uri, limit_notice_cid,
      limit_notice_posted_at, no_reply, citation_sources
    FROM invocations_old
    """

    execute "DROP TABLE invocations_old"

    execute """
    CREATE UNIQUE INDEX invocations_invocation_uri_notification_cid_index
      ON invocations (invocation_uri, notification_cid)
    """

    execute "CREATE UNIQUE INDEX invocations_reply_rkey_index ON invocations (reply_rkey)"
    execute "CREATE INDEX invocations_status_index ON invocations (status)"
    execute "CREATE INDEX invocations_defer_until_index ON invocations (defer_until)"
    execute "CREATE INDEX invocations_actor_did_index ON invocations (actor_did)"
    execute "CREATE INDEX invocations_admitted_at_index ON invocations (admitted_at)"

    execute """
    CREATE INDEX invocations_research_claim_token_index
      ON invocations (research_claim_token)
    """

    execute """
    CREATE INDEX invocations_publication_claim_token_index
      ON invocations (publication_claim_token)
    """

    execute """
    CREATE INDEX invocations_recovery_scan_index
      ON invocations (recovery_checked_at, received_at, id)
      WHERE stage IN (
        'received', 'checking_eligibility', 'capturing_thread',
        'thread_ready', 'researching', 'reply_ready', 'publishing'
      )
    """
  end

  defp failure_category_values(true) do
    failure_category_values(false) <> ", 'invalid_repair'"
  end

  defp failure_category_values(false) do
    "'invalid_input', 'identity_unavailable', 'rate_limited', 'thread_unavailable', " <>
      "'provider_auth', 'provider_budget', 'provider_response', " <>
      "'publication_auth', 'publication_conflict'"
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
