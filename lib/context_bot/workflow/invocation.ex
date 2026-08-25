defmodule ContextBot.Workflow.Invocation do
  @moduledoc """
  Durable receipt and checkpoint state for one invocation URI/CID pair.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses [
    :received,
    :deferred_capacity,
    :checking_eligibility,
    :ineligible,
    :deferred_rate,
    :capturing_thread,
    :thread_ready,
    :deferred_budget,
    :researching,
    :reply_ready,
    :publishing,
    :complete,
    :failed
  ]

  @failure_categories [
    :invalid_input,
    :identity_unavailable,
    :rate_limited,
    :thread_unavailable,
    :provider_auth,
    :provider_budget,
    :provider_response,
    :publication_auth,
    :publication_conflict
  ]

  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

  @receipt_fields [
    :dry_run,
    :target_uri,
    :invocation_text,
    :invocation_uri,
    :notification_cid,
    :current_cid,
    :actor_did,
    :actor_handle,
    :raw_notification,
    :received_at,
    :status,
    :stage
  ]

  @transition_fields [
    :current_cid,
    :status,
    :stage,
    :eligibility_method,
    :eligibility_evidence,
    :admitted_at,
    :defer_until,
    :raw_thread,
    :canonical_thread,
    :canonical_thread_version,
    :canonical_media,
    :contains_video,
    :root_uri,
    :root_cid,
    :anthropic_messages,
    :anthropic_attempt_sequence,
    :anthropic_usage,
    :deferred_attempt_kind,
    :recovery_checked_at,
    :research_claim_token,
    :research_claimed_at,
    :selected_reply,
    :reply_validation,
    :reply_repo,
    :reply_rkey,
    :reply_record,
    :reply_part2_rkey,
    :reply_part2_record,
    :publication_claim_token,
    :publication_claimed_at,
    :reply_uri,
    :reply_cid,
    :reply_part2_uri,
    :reply_part2_cid,
    :failure_category,
    :failure_detail,
    :completed_at
  ]

  @type status ::
          :received
          | :deferred_capacity
          | :checking_eligibility
          | :ineligible
          | :deferred_rate
          | :capturing_thread
          | :thread_ready
          | :deferred_budget
          | :researching
          | :reply_ready
          | :publishing
          | :complete
          | :failed

  @type t :: %__MODULE__{}

  schema "invocations" do
    field :dry_run, :boolean, default: false
    field :target_uri, :string
    field :invocation_text, :string
    field :invocation_uri, :string
    field :notification_cid, :string
    field :current_cid, :string
    field :actor_did, :string
    field :actor_handle, :string
    field :raw_notification, :map
    field :received_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses
    field :stage, Ecto.Enum, values: @statuses
    field :eligibility_method, :string
    field :eligibility_evidence, :map
    field :admitted_at, :utc_datetime_usec
    field :defer_until, :utc_datetime_usec
    field :raw_thread, :map
    field :canonical_thread, :string
    field :canonical_thread_version, :string
    field :canonical_media, {:array, :map}, default: []
    field :contains_video, :boolean, default: false
    field :root_uri, :string
    field :root_cid, :string
    field :anthropic_messages, :map
    field :anthropic_responses, {:array, :map}, default: [], load_in_query: false
    field :anthropic_attempt_sequence, :integer, default: 0
    field :anthropic_usage, :map
    field :deferred_attempt_kind, Ecto.Enum, values: [:research, :continuation, :repair, :retry]
    field :recovery_checked_at, :utc_datetime_usec
    field :research_claim_token, :string
    field :research_claimed_at, :utc_datetime_usec
    field :selected_reply, :string
    field :reply_validation, :map
    field :reply_repo, :string
    field :reply_rkey, :string
    field :reply_record, :map
    field :reply_part2_rkey, :string
    field :reply_part2_record, :map
    field :publication_claim_token, :string
    field :publication_claimed_at, :utc_datetime_usec
    field :reply_uri, :string
    field :reply_cid, :string
    field :reply_part2_uri, :string
    field :reply_part2_cid, :string
    field :failure_category, Ecto.Enum, values: @failure_categories
    field :failure_detail, :map
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invocation, attrs) do
    invocation
    |> cast(attrs, @receipt_fields ++ @transition_fields)
    |> validate_immutable_identity()
    |> validate_required([
      :dry_run,
      :invocation_uri,
      :notification_cid,
      :current_cid,
      :actor_did,
      :raw_notification,
      :received_at,
      :status,
      :stage
    ])
    |> validate_dry_run_inputs()
    |> unique_constraint([:invocation_uri, :notification_cid])
    |> unique_constraint(:reply_rkey)
    |> validate_format(:reply_repo, @did_regex)
    |> check_constraint(:status, name: :invocations_status_check)
    |> check_constraint(:stage, name: :invocations_stage_check)
    |> check_constraint(:failure_category, name: :invocations_failure_category_check)
    |> check_constraint(:dry_run, name: :dry_run_input_check)
  end

  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(invocation, attrs) do
    invocation
    |> cast(attrs, @transition_fields)
    |> validate_required([:status, :stage])
    |> unique_constraint(:reply_rkey)
    |> validate_format(:reply_repo, @did_regex)
    |> check_constraint(:status, name: :invocations_status_check)
    |> check_constraint(:stage, name: :invocations_stage_check)
    |> check_constraint(:failure_category, name: :invocations_failure_category_check)
  end

  @spec anthropic_responses_changeset(t(), [map()]) :: Ecto.Changeset.t()
  def anthropic_responses_changeset(invocation, responses) do
    change(invocation, anthropic_responses: responses)
  end

  defp validate_immutable_identity(
         %Ecto.Changeset{data: %{__meta__: %{state: :loaded}}} = changeset
       ) do
    Enum.reduce(
      [:dry_run, :target_uri, :invocation_text, :invocation_uri, :notification_cid],
      changeset,
      fn field, changeset ->
        if Map.has_key?(changeset.changes, field) do
          add_error(changeset, field, "is immutable")
        else
          changeset
        end
      end
    )
  end

  defp validate_immutable_identity(changeset), do: changeset

  defp validate_dry_run_inputs(changeset) do
    if get_field(changeset, :dry_run) do
      validate_required(changeset, [:target_uri, :invocation_text])
    else
      changeset
    end
  end
end
