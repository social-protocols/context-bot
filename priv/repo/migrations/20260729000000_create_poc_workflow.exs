defmodule ContextBot.Repo.Migrations.CreatePocWorkflow do
  use Ecto.Migration

  @statuses ~w(
    received
    deferred_capacity
    checking_eligibility
    ineligible
    deferred_rate
    capturing_thread
    thread_ready
    deferred_budget
    researching
    reply_ready
    publishing
    complete
    failed
  )

  @failure_categories ~w(
    invalid_input
    identity_unavailable
    rate_limited
    thread_unavailable
    provider_auth
    provider_budget
    provider_response
    publication_auth
    publication_conflict
  )

  def up do
    Oban.Migration.up(version: 14)

    create table(:invocations) do
      add :invocation_uri, :text, null: false
      add :notification_cid, :text, null: false
      add :current_cid, :text, null: false
      add :actor_did, :text, null: false
      add :actor_handle, :text
      add :raw_notification, :map, null: false
      add :received_at, :utc_datetime_usec, null: false

      add :status, :text,
        null: false,
        check: %{
          name: "invocations_status_check",
          expr: "status IN (#{quoted_values(@statuses)})"
        }

      add :stage, :text,
        null: false,
        check: %{
          name: "invocations_stage_check",
          expr: "stage IN (#{quoted_values(@statuses)})"
        }

      add :eligibility_method, :text
      add :eligibility_evidence, :map
      add :admitted_at, :utc_datetime_usec
      add :defer_until, :utc_datetime_usec
      add :raw_thread, :map
      add :canonical_thread, :text
      add :canonical_thread_version, :text
      add :root_uri, :text
      add :root_cid, :text
      add :anthropic_messages, :map
      add :anthropic_responses, :map, null: false, default: fragment("'[]'")
      add :anthropic_attempt_sequence, :integer, null: false, default: 0
      add :anthropic_usage, :map
      add :selected_reply, :text
      add :reply_validation, :map
      add :reply_rkey, :text
      add :reply_record, :map
      add :reply_uri, :text
      add :reply_cid, :text

      add :failure_category, :text,
        check: %{
          name: "invocations_failure_category_check",
          expr:
            "failure_category IS NULL OR failure_category IN (#{quoted_values(@failure_categories)})"
        }

      add :failure_detail, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invocations, [:invocation_uri, :notification_cid])
    create unique_index(:invocations, [:reply_rkey])
    create index(:invocations, [:status])
    create index(:invocations, [:defer_until])
    create index(:invocations, [:actor_did])
    create index(:invocations, [:admitted_at])
  end

  def down do
    drop table(:invocations)
    Oban.Migration.down(version: 1)
  end

  defp quoted_values(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
