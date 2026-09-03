defmodule ContextBot.Research.Citations do
  @moduledoc """
  Extracts citation URLs and cited_text from Anthropic citation blocks.

  Only URLs that appear on citation objects are kept. This module never
  invents or reconstructs a URL from titles, tool results, or writeup text.
  """

  @type citation :: %{optional(String.t()) => String.t()}

  @spec from_content([map()]) :: [citation()]
  def from_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(&block_citations/1)
    |> dedupe()
  end

  def from_content(_blocks), do: []

  @spec urls([citation()]) :: [String.t()]
  def urls(records) when is_list(records) do
    records
    |> Enum.map(& &1["url"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def urls(_records), do: []

  @doc """
  Returns the research writeup, appending a Sources section from extracted
  citation URLs only when the writeup has no visible `https://` links.
  """
  @spec publishable_writeup(String.t(), [citation()]) :: String.t()
  def publishable_writeup(writeup, records) when is_binary(writeup) and is_list(records) do
    urls = urls(records)
    trimmed = String.trim(writeup)

    cond do
      urls == [] -> trimmed
      has_visible_https?(trimmed) -> trimmed
      true -> trimmed <> "\n\n## Sources\n\n" <> Enum.map_join(urls, "\n", &"- #{&1}")
    end
  end

  defp block_citations(%{"citations" => citations}) when is_list(citations) do
    Enum.flat_map(citations, &citation_record/1)
  end

  defp block_citations(_block), do: []

  defp citation_record(citation) when is_map(citation) do
    url = citation["url"]
    cited = citation["cited_text"]

    cond do
      http_url?(url) ->
        [maybe_put_cited(%{"url" => url}, cited)]

      is_binary(url) and String.trim(url) != "" ->
        []

      is_binary(cited) and String.trim(cited) != "" ->
        [%{"cited_text" => String.trim(cited)}]

      true ->
        []
    end
  end

  defp citation_record(_citation), do: []

  defp http_url?(url) when is_binary(url),
    do: String.starts_with?(url, "https://") or String.starts_with?(url, "http://")

  defp http_url?(_url), do: false

  defp maybe_put_cited(record, cited) when is_binary(cited) and cited != "",
    do: Map.put(record, "cited_text", cited)

  defp maybe_put_cited(record, _cited), do: record

  defp dedupe(records) do
    {kept, _seen} =
      Enum.reduce(records, {[], MapSet.new()}, fn record, {acc, seen} ->
        key = {record["url"], record["cited_text"]}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [record], MapSet.put(seen, key)}
        end
      end)

    kept
  end

  defp has_visible_https?(text), do: String.contains?(text, "https://")
end
