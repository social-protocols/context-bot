defmodule ContextBot.Research.BudgetEntry do
  @moduledoc """
  One durable reservation and its maximum billable Anthropic exposure.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ContextBot.Workflow.Invocation

  @kinds [:research, :continuation, :repair, :retry]
  @states [:reserved, :sent, :settled, :indeterminate]

  @type kind :: :research | :continuation | :repair | :retry
  @type state :: :reserved | :sent | :settled | :indeterminate
  @type t :: %__MODULE__{}

  schema "api_budget_entries" do
    field :attempt_key, :string
    field :budget_date, :date
    field :kind, Ecto.Enum, values: @kinds
    field :reserved_microdollars, :integer
    field :settled_microdollars, :integer
    field :state, Ecto.Enum, values: @states
    field :usage, :map
    field :pricing_version, :string
    field :sent_at, :utc_datetime_usec
    field :response_recorded_at, :utc_datetime_usec

    belongs_to :invocation, Invocation

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    changeset =
      entry
      |> cast(attrs, [
        :attempt_key,
        :invocation_id,
        :budget_date,
        :kind,
        :reserved_microdollars,
        :settled_microdollars,
        :state,
        :usage,
        :pricing_version,
        :sent_at,
        :response_recorded_at
      ])
      |> validate_required([
        :attempt_key,
        :invocation_id,
        :budget_date,
        :kind,
        :reserved_microdollars,
        :state
      ])
      |> validate_number(:reserved_microdollars, greater_than_or_equal_to: 0)

    changeset
    |> validate_settlement_range()
    |> foreign_key_constraint(:invocation_id)
    |> unique_constraint(:attempt_key)
    |> check_constraint(:kind, name: :api_budget_entries_kind_check)
    |> check_constraint(:reserved_microdollars,
      name: :api_budget_entries_reserved_nonnegative_check
    )
    |> check_constraint(:settled_microdollars, name: :api_budget_entries_settled_range_check)
    |> check_constraint(:state, name: :api_budget_entries_state_check)
  end

  defp validate_settlement_range(changeset) do
    case get_field(changeset, :reserved_microdollars) do
      reserved when is_integer(reserved) ->
        validate_number(changeset, :settled_microdollars,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: reserved
        )

      _missing ->
        changeset
    end
  end
end
