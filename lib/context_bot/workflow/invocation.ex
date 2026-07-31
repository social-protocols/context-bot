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

  @receipt_fields [
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
    :root_uri,
    :root_cid,
    :anthropic_messages,
    :anthropic_attempt_sequence,
    :anthropic_usage,
    :research_claim_token,
    :research_claimed_at,
    :selected_reply,
    :reply_validation,
    :reply_rkey,
    :reply_record,
    :reply_uri,
    :reply_cid,
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
    field :root_uri, :string
    field :root_cid, :string
    field :anthropic_messages, :map
    field :anthropic_responses, {:array, :map}, default: []
    field :anthropic_attempt_sequence, :integer, default: 0
    field :anthropic_usage, :map
    field :research_claim_token, :string
    field :research_claimed_at, :utc_datetime_usec
    field :selected_reply, :string
    field :reply_validation, :map
    field :reply_rkey, :string
    field :reply_record, :map
    field :reply_uri, :string
    field :reply_cid, :string
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
      :invocation_uri,
      :notification_cid,
      :current_cid,
      :actor_did,
      :raw_notification,
      :received_at,
      :status,
      :stage
    ])
    |> unique_constraint([:invocation_uri, :notification_cid])
    |> unique_constraint(:reply_rkey)
    |> check_constraint(:status, name: :invocations_status_check)
    |> check_constraint(:stage, name: :invocations_stage_check)
    |> check_constraint(:failure_category, name: :invocations_failure_category_check)
  end

  @spec transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def transition_changeset(invocation, attrs) do
    invocation
    |> cast(attrs, @transition_fields)
    |> validate_required([:status, :stage])
    |> unique_constraint(:reply_rkey)
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
    Enum.reduce([:invocation_uri, :notification_cid], changeset, fn field, changeset ->
      if Map.has_key?(changeset.changes, field) do
        add_error(changeset, field, "is immutable")
      else
        changeset
      end
    end)
  end

  defp validate_immutable_identity(changeset), do: changeset
end
