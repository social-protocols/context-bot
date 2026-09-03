defmodule ContextBotWeb.PublicRecord do
  @moduledoc """
  JSON-safe dumps of product SQLite rows.

  Every schema column is included. `:binary` columns are Base64 so the exact
  stored bytes remain recoverable. Envelope metadata is also decoded so a
  browser can inspect a run without reconstructing an Erlang term.
  """

  alias ContextBot.Research.ResponseEnvelope

  @type json_term ::
          nil
          | boolean()
          | integer()
          | float()
          | String.t()
          | [json_term()]
          | %{optional(atom() | String.t()) => json_term()}

  @spec dump(struct()) :: %{optional(atom()) => json_term()}
  def dump(%ResponseEnvelope{} = envelope) do
    envelope
    |> dump_fields()
    |> Map.put(:metadata, decode_metadata(envelope.metadata_blob))
  end

  def dump(%_{} = record), do: dump_fields(record)

  defp dump_fields(%mod{} = record) do
    Map.new(mod.__schema__(:fields), fn field ->
      {field, encode_value(mod.__schema__(:type, field), Map.fetch!(record, field))}
    end)
  end

  defp encode_value(_type, nil), do: nil
  defp encode_value(:binary, value) when is_binary(value), do: Base.encode64(value)
  defp encode_value(_type, %DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(_type, %NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_value(_type, %Date{} = value), do: Date.to_iso8601(value)
  defp encode_value(_type, %Time{} = value), do: Time.to_iso8601(value)

  defp encode_value(_type, value) when is_atom(value) and value not in [true, false] do
    Atom.to_string(value)
  end

  defp encode_value(_type, value) when is_list(value) do
    Enum.map(value, &encode_value(nil, &1))
  end

  defp encode_value(_type, %_{} = value), do: dump(value)

  defp encode_value(_type, value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {encode_key(key), encode_value(nil, nested)} end)
  end

  defp encode_value(_type, value) when is_tuple(value) do
    value |> Tuple.to_list() |> encode_value(nil)
  end

  defp encode_value(_type, value), do: value

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(key), do: to_string(key)

  defp decode_metadata(blob) when is_binary(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      metadata when is_map(metadata) -> encode_value(nil, metadata)
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp decode_metadata(_blob), do: nil
end
