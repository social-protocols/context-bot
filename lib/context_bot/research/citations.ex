defmodule ContextBot.Research.Citations do
  @moduledoc """
  Extracts citation URLs, titles, and cited_text from Anthropic citation blocks
  and materializes numbered markers plus one Sources list for new writeups.

  Only URLs that appear on citation objects are kept. This module never
  invents or reconstructs a URL from titles, tool results, or writeup text.
  Existing published PDS records are not rewritten here; callers apply this
  only when building a new document.
  """

  @type citation :: %{optional(String.t()) => String.t()}

  @sources_heading ~r/^(\#{1,6})[ \t]+Sources[ \t]*:?[ \t]*$/i
  @atx_heading ~r/^(\#{1,6})[ \t]+\S/
  @leading_markers ~r/\A((?:\[\d+\])+)/u
  @marker_number ~r/\[(\d+)\]/u
  @max_title_graphemes 80

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
    |> Enum.filter(&http_url?/1)
    |> Enum.uniq()
  end

  def urls(_records), do: []

  @doc """
  Returns the research writeup with inline `[n]` markers after each cited span
  or `cited_text` match, and exactly one titled Sources list.

  Same allowlisted URL reuses the same number. A model-written Sources section
  is replaced. GFM `[^n]` footnotes are never emitted. URLs are taken only
  from citation objects.
  """
  @spec publishable_writeup(String.t(), [citation()]) :: String.t()
  def publishable_writeup(writeup, records) when is_binary(writeup) and is_list(records) do
    trimmed = String.trim(writeup)
    numbered = number_allowlisted(records)

    if numbered == [] do
      strip_sources_sections(trimmed)
    else
      trimmed
      |> strip_sources_sections()
      |> insert_markers(numbered)
      |> append_sources(unique_sources(numbered))
    end
  end

  defp block_citations(%{"citations" => citations} = block) when is_list(citations) do
    span = text_span(block)
    Enum.flat_map(citations, &citation_record(&1, span))
  end

  defp block_citations(_block), do: []

  defp text_span(%{"text" => text}) when is_binary(text) and text != "", do: text
  defp text_span(_block), do: nil

  defp citation_record(citation, span) when is_map(citation) do
    url = citation["url"]
    cited = citation["cited_text"]
    title = citation["title"]

    cond do
      http_url?(url) ->
        [decorate(%{"url" => url}, cited, title, span)]

      is_binary(url) and String.trim(url) != "" ->
        []

      present?(cited) ->
        [decorate(%{"cited_text" => String.trim(cited)}, nil, title, span)]

      true ->
        []
    end
  end

  defp citation_record(_citation, _span), do: []

  defp decorate(record, cited, title, span) do
    record
    |> maybe_put_cited(cited)
    |> maybe_put_title(title)
    |> maybe_put_span(span)
  end

  defp maybe_put_cited(record, cited) when is_binary(cited) and cited != "",
    do: Map.put(record, "cited_text", cited)

  defp maybe_put_cited(record, _cited), do: record

  defp maybe_put_title(record, title) when is_binary(title) do
    case String.trim(title) do
      "" -> record
      trimmed -> Map.put(record, "title", trimmed)
    end
  end

  defp maybe_put_title(record, _title), do: record

  defp maybe_put_span(record, span) when is_binary(span) and span != "",
    do: Map.put(record, "span", span)

  defp maybe_put_span(record, _span), do: record

  defp dedupe(records) do
    {kept, _seen} =
      Enum.reduce(records, {[], MapSet.new()}, fn record, {acc, seen} ->
        key = {record["url"], record["cited_text"], record["span"]}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[record | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(kept)
  end

  defp number_allowlisted(records) do
    {numbered, _assigned} = Enum.reduce(records, {[], %{}}, &assign_number/2)
    Enum.reverse(numbered)
  end

  defp assign_number(record, {acc, assigned} = acc_pair) do
    url = record["url"]

    if http_url?(url) do
      assign_http_number(url, record, acc, assigned)
    else
      acc_pair
    end
  end

  defp assign_http_number(url, record, acc, assigned) do
    case Map.fetch(assigned, url) do
      {:ok, number} ->
        {[{number, record} | acc], assigned}

      :error ->
        number = map_size(assigned) + 1
        {[{number, record} | acc], Map.put(assigned, url, number)}
    end
  end

  defp unique_sources(numbered) do
    numbered
    |> Enum.uniq_by(fn {number, _record} -> number end)
    |> Enum.map(fn {number, record} ->
      {number, record["url"], source_title(record)}
    end)
  end

  defp source_title(record) do
    cond do
      present?(record["title"]) -> compact_title(record["title"])
      present?(record["cited_text"]) -> compact_title(record["cited_text"])
      true -> host_title(record["url"])
    end
  end

  defp compact_title(text) do
    compacted = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(compacted) <= @max_title_graphemes do
      compacted
    else
      String.slice(compacted, 0, @max_title_graphemes - 1) <> "…"
    end
  end

  defp host_title(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> url
    end
  end

  defp insert_markers(text, numbered) do
    numbered
    |> Enum.chunk_by(&chunk_key/1)
    |> Enum.reduce({text, 0}, &insert_chunk/2)
    |> elem(0)
  end

  defp chunk_key({_number, record}) do
    case record["span"] do
      span when is_binary(span) and span != "" -> {:span, span}
      _missing -> {:cited, record["cited_text"]}
    end
  end

  defp insert_chunk(chunk, {text, cursor}) do
    {_number, record} = hd(chunk)
    numbers = chunk |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    case find_match(text, record, cursor) do
      {:ok, end_idx} ->
        {updated, consumed} = put_markers(text, end_idx, numbers)
        {updated, end_idx + consumed}

      :error ->
        {text, cursor}
    end
  end

  defp find_match(text, record, cursor) do
    [record["span"], record["cited_text"]]
    |> Enum.flat_map(&needles_for/1)
    |> Enum.find_value(:error, fn needle ->
      case find_from(text, needle, cursor) do
        {:ok, end_idx} -> {:ok, end_idx}
        :error -> nil
      end
    end)
  end

  defp needles_for(value) when is_binary(value) and value != "" do
    [value, String.trim(value), strip_sources_sections(value)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp needles_for(_value), do: []

  defp find_from(_text, "", _cursor), do: :error

  defp find_from(text, needle, cursor) do
    {_prefix, rest} = String.split_at(text, cursor)

    case String.split(rest, needle, parts: 2) do
      [_] ->
        :error

      [left, _right] ->
        {:ok, cursor + String.length(left) + String.length(needle)}
    end
  end

  defp put_markers(text, idx, numbers) do
    {left, right} = String.split_at(text, idx)
    {existing, existing_len} = leading_marker_numbers(right)
    missing = Enum.reject(numbers, &(&1 in existing))
    markers = Enum.map_join(missing, fn number -> "[#{number}]" end)
    {before, after_existing} = String.split_at(right, existing_len)

    {left <> before <> markers <> after_existing, existing_len + String.length(markers)}
  end

  defp leading_marker_numbers(text) do
    case Regex.run(@leading_markers, text) do
      [_, run] ->
        numbers =
          @marker_number
          |> Regex.scan(run)
          |> Enum.map(fn [_, number] -> String.to_integer(number) end)

        {numbers, String.length(run)}

      nil ->
        {[], 0}
    end
  end

  defp strip_sources_sections(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> drop_sources_sections([])
    |> Enum.join("\n")
    |> String.trim()
  end

  defp drop_sources_sections([], acc), do: Enum.reverse(acc)

  defp drop_sources_sections([line | rest], acc) do
    case sources_heading_level(line) do
      nil ->
        drop_sources_sections(rest, [line | acc])

      level ->
        rest
        |> drop_until_heading(level)
        |> drop_sources_sections(acc)
    end
  end

  defp drop_until_heading([], _level), do: []

  defp drop_until_heading([line | rest] = lines, level) do
    case heading_level(line) do
      heading when is_integer(heading) and heading <= level ->
        lines

      _other ->
        drop_until_heading(rest, level)
    end
  end

  defp sources_heading_level(line) do
    case Regex.run(@sources_heading, strip_cr(line)) do
      [_, hashes] -> String.length(hashes)
      nil -> nil
    end
  end

  defp heading_level(line) do
    case Regex.run(@atx_heading, strip_cr(line)) do
      [_, hashes] -> String.length(hashes)
      nil -> nil
    end
  end

  defp strip_cr(line), do: String.trim_trailing(line, "\r")

  defp append_sources(text, sources) do
    list =
      Enum.map_join(sources, "\n", fn {number, url, title} ->
        "#{number}. [#{escape_link_text(title)}](#{url})"
      end)

    text <> "\n\n## Sources\n\n" <> list
  end

  defp escape_link_text(title) do
    title
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp http_url?(url) when is_binary(url),
    do: String.starts_with?(url, "https://") or String.starts_with?(url, "http://")

  defp http_url?(_url), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
