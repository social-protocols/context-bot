defmodule ContextBot.Research.ResponseEnvelope do
  @moduledoc """
  One ordered Anthropic HTTP envelope with its raw body stored as an exact SQLite BLOB.

  Envelope metadata is encoded before the persistence transaction and decoded only after it.
  Indexed attempt fields stay queryable without interpreting provider bytes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.Invocation

  @max_overhead_bytes 65_536
  @kinds [:research, :continuation, :repair, :structure, :retry]
  @persisted_fields [
    :invocation_id,
    :budget_entry_id,
    :attempt_key,
    :kind,
    :status,
    :metadata_blob,
    :raw_body,
    :received_at,
    :duration_ms,
    :storage_bytes
  ]

  @type t :: %__MODULE__{}

  @doc "Maximum retained bytes beyond the exact raw provider response body."
  @spec max_overhead_bytes() :: pos_integer()
  def max_overhead_bytes, do: @max_overhead_bytes

  schema "anthropic_response_envelopes" do
    field :attempt_key, :string
    field :kind, Ecto.Enum, values: @kinds
    field :status, :integer
    field :metadata_blob, :binary
    field :raw_body, :binary
    field :received_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :storage_bytes, :integer

    belongs_to :invocation, Invocation
    belongs_to :budget_entry, BudgetEntry

    timestamps(type: :utc_datetime_usec)
  end

  @spec prepare(map(), map()) :: map()
  def prepare(response, tags \\ %{}) when is_map(response) and is_map(tags) do
    raw_body = fetch(response, :raw_body)

    metadata =
      response
      |> Map.drop([:raw_body, "raw_body"])
      |> Map.merge(tags)

    attempt_key = fetch(metadata, :attempt_key)
    kind = fetch(metadata, :kind)
    {metadata, metadata_blob} = bounded_metadata(metadata, attempt_key, kind)

    %{
      attempt_key: attempt_key,
      kind: normalize_kind(kind),
      status: fetch(metadata, :status),
      metadata_blob: metadata_blob,
      raw_body: raw_body,
      received_at: fetch(metadata, :received_at),
      duration_ms: fetch(metadata, :duration_ms),
      storage_bytes:
        byte_size(raw_body) + byte_size(metadata_blob) + nullable_byte_size(attempt_key) +
          nullable_byte_size(kind)
    }
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, @persisted_fields, empty_values: [])
    |> validate_required([:invocation_id, :metadata_blob, :storage_bytes])
    |> validate_raw_body()
    |> validate_number(:storage_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:invocation_id)
    |> foreign_key_constraint(:budget_entry_id)
    |> unique_constraint(:budget_entry_id)
    |> unique_constraint(:attempt_key)
    |> check_constraint(:kind, name: :anthropic_response_envelopes_kind_check)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    metadata = :erlang.binary_to_term(response.metadata_blob, [:safe])

    metadata
    |> Map.put(:raw_body, response.raw_body)
    |> Map.put(:storage_bytes, response.storage_bytes)
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp normalize_kind(kind) when kind in @kinds, do: kind
  defp normalize_kind(kind) when is_binary(kind), do: String.to_existing_atom(kind)
  defp normalize_kind(nil), do: nil

  defp nullable_byte_size(value) when is_binary(value), do: byte_size(value)
  defp nullable_byte_size(value) when is_atom(value), do: value |> Atom.to_string() |> byte_size()
  defp nullable_byte_size(_value), do: 0

  defp bounded_metadata(metadata, attempt_key, kind) do
    case encode_metadata(metadata, attempt_key, kind) do
      {:ok, metadata_blob} ->
        {metadata, metadata_blob}

      :too_large ->
        truncated =
          metadata
          |> Map.drop([:headers, "headers"])
          |> Map.put(:headers, %{})
          |> Map.put(:headers_truncated, true)

        case encode_metadata(truncated, attempt_key, kind) do
          {:ok, metadata_blob} -> {truncated, metadata_blob}
          :too_large -> raise ArgumentError, "provider response envelope metadata is too large"
        end
    end
  end

  defp encode_metadata(metadata, attempt_key, kind) do
    metadata_blob = :erlang.term_to_binary(metadata, [:deterministic])

    overhead_bytes =
      byte_size(metadata_blob) + nullable_byte_size(attempt_key) + nullable_byte_size(kind)

    if overhead_bytes <= @max_overhead_bytes, do: {:ok, metadata_blob}, else: :too_large
  end

  defp validate_raw_body(changeset) do
    case get_field(changeset, :raw_body) do
      raw_body when is_binary(raw_body) -> changeset
      _missing_or_invalid -> add_error(changeset, :raw_body, "must be binary")
    end
  end
end
