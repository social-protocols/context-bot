defmodule ContextBotWeb.PublicData do
  @moduledoc """
  Read-only loaders for the public product-database JSON API.

  Invocation queries that need `anthropic_responses` select that
  `load_in_query: false` column on purpose. The HTML dashboard keeps using
  its cheaper projected select.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Research.ResponseEnvelope
  alias ContextBot.Workflow.Invocation
  alias ContextBotWeb.PublicRecord

  @type id_param :: String.t() | integer()
  @type json_document :: %{optional(atom()) => PublicRecord.json_term()}

  @spec parse_id(id_param()) :: pos_integer() | nil
  def parse_id(id) when is_integer(id) and id > 0, do: id

  def parse_id(id) when is_binary(id) do
    trimmed = String.replace_suffix(id, ".json", "")

    case Integer.parse(trimmed) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  def parse_id(_id), do: nil

  @spec list_invocations() :: [json_document()]
  def list_invocations, do: list(Invocation)

  @spec invocation_document(id_param()) :: json_document() | nil
  def invocation_document(id) do
    with parsed when is_integer(parsed) <- parse_id(id),
         %Invocation{} = invocation <- get_by_id(Invocation, parsed) do
      invocation
      |> PublicRecord.dump()
      |> Map.put(:budget_entries, related(BudgetEntry, parsed))
      |> Map.put(:anthropic_response_envelopes, related(ResponseEnvelope, parsed))
    else
      _missing -> nil
    end
  end

  @spec list_budget_entries() :: [json_document()]
  def list_budget_entries, do: list(BudgetEntry)

  @spec get_budget_entry(id_param()) :: json_document() | nil
  def get_budget_entry(id), do: get_dumped(BudgetEntry, id)

  @spec list_response_envelopes() :: [json_document()]
  def list_response_envelopes, do: list(ResponseEnvelope)

  @spec get_response_envelope(id_param()) :: json_document() | nil
  def get_response_envelope(id), do: get_dumped(ResponseEnvelope, id)

  defp list(module) do
    module
    |> from()
    |> order_by([row], desc: row.id)
    |> select_schema_fields(module)
    |> Repo.all()
    |> Enum.map(&PublicRecord.dump/1)
  end

  defp get_dumped(module, id) do
    case parse_id(id) do
      nil -> nil
      parsed -> parsed |> then(&get_by_id(module, &1)) |> dump_or_nil()
    end
  end

  defp get_by_id(module, id) do
    module
    |> from()
    |> where([row], row.id == ^id)
    |> select_schema_fields(module)
    |> Repo.one()
  end

  defp related(module, invocation_id) do
    module
    |> from()
    |> where([row], row.invocation_id == ^invocation_id)
    |> order_by([row], asc: row.id)
    |> select_schema_fields(module)
    |> Repo.all()
    |> Enum.map(&PublicRecord.dump/1)
  end

  defp select_schema_fields(query, module) do
    select(query, [row], struct(row, ^module.__schema__(:fields)))
  end

  defp dump_or_nil(nil), do: nil
  defp dump_or_nil(record), do: PublicRecord.dump(record)
end
