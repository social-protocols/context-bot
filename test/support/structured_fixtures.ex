defmodule ContextBot.Research.StructuredFixtures do
  @moduledoc false

  @default_title "Context Request"

  @spec structured_json(String.t(), keyword()) :: String.t()
  def structured_json(compact, opts \\ []) when is_binary(compact) do
    Jason.encode!(structured_map(compact, opts))
  end

  @spec no_reply_json(keyword()) :: String.t()
  def no_reply_json(opts \\ []) do
    Jason.encode!(
      %{
        "disposition" => "no_reply",
        "title" => Keyword.get(opts, :title, ""),
        "compact_reply" => Keyword.get(opts, :compact, "")
      }
      |> maybe_put_full(Keyword.get(opts, :full, :omit))
      |> maybe_drop_empty_fields(Keyword.get(opts, :omit_fields, false))
    )
  end

  @spec selected(String.t(), keyword()) ::
          {:ok,
           %{
             text: String.t(),
             full_response: String.t(),
             document_title: String.t(),
             disposition: :reply
           }}
  def selected(compact, opts \\ []) when is_binary(compact) do
    {:ok,
     %{
       text: compact,
       full_response: Keyword.get(opts, :full, ""),
       document_title: Keyword.get(opts, :title, @default_title),
       disposition: :reply
     }}
  end

  defp structured_map(compact, opts) do
    %{
      "disposition" => Keyword.get(opts, :disposition, "reply"),
      "title" => Keyword.get(opts, :title, @default_title),
      "compact_reply" => compact
    }
    |> maybe_put_full(Keyword.get(opts, :full, :omit))
    |> maybe_omit_disposition(Keyword.get(opts, :omit_disposition, false))
  end

  defp maybe_put_full(map, :omit), do: map
  defp maybe_put_full(map, full) when is_binary(full), do: Map.put(map, "full_response", full)

  defp maybe_omit_disposition(map, true), do: Map.delete(map, "disposition")
  defp maybe_omit_disposition(map, _false), do: map

  defp maybe_drop_empty_fields(map, true) do
    Map.drop(map, ["title", "compact_reply", "full_response"])
  end

  defp maybe_drop_empty_fields(map, _false), do: map
end
