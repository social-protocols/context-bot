defmodule ContextBot.Repo.Migrations.AddInvalidRepairFailureCategory do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute "PRAGMA foreign_keys=OFF"

    rebuild_invocations()

    execute "PRAGMA foreign_keys=ON"
  end

  def down do
    execute "PRAGMA foreign_keys=OFF"

    rebuild_invocations(include_invalid_repair?: false)

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

  defp drop_index_if_exists(name) do
    execute "DROP INDEX IF EXISTS #{name}"
  end
end
