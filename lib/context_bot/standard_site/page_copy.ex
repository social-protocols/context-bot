defmodule ContextBot.StandardSite.PageCopy do
  @moduledoc """
  Builds Standard Reader title, description, and Asked-block copy from the invoking post.

  New full-response documents only. Existing published records are not rewritten.
  """

  alias ContextBot.ATProto.ATURI
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @mention_feature "app.bsky.richtext.facet#mention"
  @public_bot_handle "getcontext.bot"
  @bsky_profile_base "https://bsky.app/profile"
  @title_max_graphemes 80
  @title_max_words 12
  @title_word_cap 6
  @short_title_max_words 8
  @short_title_max_graphemes 60
  @description_card_graphemes 300
  @description_lexicon_graphemes 3_000
  @fallback_title "Context request"

  @type content :: %{optional(atom()) => term()}
  @type settings :: Settings.t() | map()
  @type subject :: %{
          asked_text: String.t(),
          parent_uri: String.t() | nil,
          invocation_uri: String.t() | nil
        }

  @doc "Card-length cap for `description`. The lexicon hard cap is 3000 graphemes."
  @spec description_max_graphemes() :: pos_integer()
  def description_max_graphemes, do: @description_card_graphemes

  @doc """
  Extracts stripped invocation text and an optional parent URI.

  Missing parent data is omitted. Document create must not fail for that reason.
  """
  @spec subject(Invocation.t() | map(), settings()) :: subject()
  def subject(invocation, settings) do
    record = invocation_record(invocation)

    %{
      asked_text:
        strip_bot_mentions(
          raw_invocation_text(record, invocation),
          record || %{},
          setting(settings, :bot_did),
          setting(settings, :bot_handle)
        ),
      parent_uri: parent_uri(record),
      invocation_uri: field(invocation, :invocation_uri)
    }
  end

  @doc "Removes the bot mention from invoking-post text. Invalid facets are ignored."
  @spec strip_bot_mentions(term(), map() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def strip_bot_mentions(text, record, bot_did, bot_handle) when is_binary(text) do
    text
    |> strip_facet_mentions(record, bot_did)
    |> strip_handle_mentions(bot_handle)
    |> strip_handle_mentions(@public_bot_handle)
    |> normalize_whitespace()
  end

  def strip_bot_mentions(_text, _record, _bot_did, _bot_handle), do: ""

  @doc """
  Short headline of the question.

  Prefers a usable model `document_title` when present. Otherwise uses the stripped
  invocation text, or a tight truncation of that text. Never uses the invocation TID.
  """
  @spec title(content()) :: String.t()
  def title(content) when is_map(content) do
    asked = asked_text(content)
    reply = optional_text(content, :selected_reply)
    model_title = optional_text(content, :document_title)

    cond do
      usable_model_title?(model_title, reply) -> normalize_title(model_title)
      asked == "" -> @fallback_title
      short_enough?(asked) -> normalize_title(asked)
      true -> asked |> first_words(@title_word_cap) |> normalize_title()
    end
  end

  @doc "Optional excerpt: stripped invocation text, capped for a Reader card."
  @spec description(content()) :: String.t() | nil
  def description(content) when is_map(content) do
    case asked_text(content) do
      "" ->
        nil

      asked ->
        cap = min(@description_card_graphemes, @description_lexicon_graphemes)
        truncate_graphemes(asked, cap)
    end
  end

  @doc """
  Markdown Asked block placed above `# Research Analysis`.

  Includes a public bsky.app link to the invoking post. A parent link is added only
  when the invocation is a reply and that URI is parseable.
  """
  @spec asked_markdown(content()) :: String.t()
  def asked_markdown(content) when is_map(content) do
    text = asked_text(content)
    invocation_url = bsky_url(field(content, :invocation_uri))
    parent_url = bsky_url(field(content, :parent_uri))

    [
      "## Asked",
      text_lines(text),
      link_line(invocation_url, "Invoking post"),
      link_line(parent_url, "Parent post")
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp text_lines(""), do: []
  defp text_lines(text), do: ["", text]

  defp link_line(nil, _label), do: []
  defp link_line(url, label), do: ["", "[#{label}](#{url})"]

  defp invocation_record(invocation) do
    thread = field(invocation, :raw_thread)
    notification = field(invocation, :raw_notification)

    thread_target_record(thread) ||
      notification_record(notification)
  end

  defp thread_target_record(%{"thread" => %{"post" => %{"record" => record}}})
       when is_map(record),
       do: record

  defp thread_target_record(_thread), do: nil

  defp notification_record(%{"record" => record}) when is_map(record), do: record
  defp notification_record(%{"post" => %{"record" => record}}) when is_map(record), do: record
  defp notification_record(_notification), do: nil

  defp raw_invocation_text(%{"text" => text}, _invocation) when is_binary(text), do: text

  defp raw_invocation_text(_record, invocation) do
    case field(invocation, :invocation_text) do
      text when is_binary(text) -> text
      _missing -> ""
    end
  end

  defp parent_uri(%{"reply" => %{"parent" => %{"uri" => uri}}}) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, _parsed} -> uri
      :error -> nil
    end
  end

  defp parent_uri(_record), do: nil

  defp strip_facet_mentions(text, record, bot_did)
       when is_binary(text) and is_map(record) and is_binary(bot_did) do
    case mention_ranges(record, text, bot_did) do
      {:ok, ranges} -> remove_ranges(text, ranges)
      :error -> text
    end
  end

  defp strip_facet_mentions(text, _record, _bot_did), do: text

  defp mention_ranges(record, text, bot_did) do
    case record["facets"] || record[:facets] do
      facets when is_list(facets) -> collect_mention_ranges(facets, text, bot_did)
      _invalid -> :error
    end
  end

  defp collect_mention_ranges(facets, text, bot_did) do
    ranges =
      facets
      |> Enum.filter(&targets_bot?(&1, bot_did))
      |> Enum.flat_map(&mention_range_list(&1, text))
      |> Enum.uniq()
      |> Enum.sort_by(&elem(&1, 0))

    if ranges == [] or overlapping?(ranges), do: :error, else: {:ok, ranges}
  end

  defp mention_range_list(facet, text) do
    case mention_range(facet, text) do
      {:ok, range} -> [range]
      :error -> []
    end
  end

  defp overlapping?(ranges) do
    ranges
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [{_first, previous_last}, {next_first, _last}] ->
      next_first < previous_last
    end)
  end

  defp targets_bot?(%{"features" => features}, bot_did) when is_list(features) do
    Enum.any?(features, fn
      %{"$type" => @mention_feature, "did" => ^bot_did} -> true
      _other -> false
    end)
  end

  defp targets_bot?(_facet, _bot_did), do: false

  defp mention_range(%{"index" => %{"byteStart" => first, "byteEnd" => last}}, text)
       when is_binary(text) and is_integer(first) and is_integer(last) do
    if first >= 0 and first < last and last <= byte_size(text) and
         valid_mention_bytes?(first, last, text) do
      {:ok, {first, last}}
    else
      :error
    end
  end

  defp mention_range(_facet, _text), do: :error

  defp valid_mention_bytes?(first, last, text) do
    prefix = binary_part(text, 0, first)
    mention = binary_part(text, first, last - first)
    suffix = binary_part(text, last, byte_size(text) - last)

    String.valid?(prefix) and String.valid?(mention) and String.valid?(suffix) and
      String.starts_with?(mention, "@") and not Regex.match?(~r/\s/u, mention)
  end

  defp remove_ranges(text, ranges) do
    ranges
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(text, fn {first, last}, current ->
      prefix = binary_part(current, 0, first)
      suffix = binary_part(current, last, byte_size(current) - last)
      prefix <> suffix
    end)
  end

  defp strip_handle_mentions(text, handle)
       when is_binary(text) and is_binary(handle) and handle != "" do
    escaped = Regex.escape(handle)
    String.replace(text, ~r/@#{escaped}(?=$|[\s.,!?;:)\]])/iu, "")
  end

  defp strip_handle_mentions(text, _handle), do: text

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp asked_text(content) do
    case field(content, :asked_text) do
      text when is_binary(text) -> String.trim(text)
      _missing -> ""
    end
  end

  defp optional_text(content, key) do
    case field(content, key) do
      text when is_binary(text) -> String.trim(text)
      _missing -> nil
    end
  end

  defp usable_model_title?(title, reply)
       when is_binary(title) and title != "" do
    graphemes = String.length(title)
    word_count = length(words(title))

    graphemes <= @title_max_graphemes and word_count > 0 and word_count <= @title_max_words and
      not tid_like?(title) and not context_on_prefix?(title) and
      not looks_like_reply?(title, reply)
  end

  defp usable_model_title?(_title, _reply), do: false

  defp tid_like?(title) do
    compact =
      title
      |> String.replace(~r/\AContext on\s+/i, "")
      |> String.replace(~r/\.+\z/u, "")
      |> String.trim()

    Regex.match?(~r/\A[2-7a-z]{8,20}\z/, compact)
  end

  defp context_on_prefix?(title), do: String.starts_with?(String.downcase(title), "context on ")

  defp looks_like_reply?(_title, reply) when not is_binary(reply) or reply == "", do: false

  defp looks_like_reply?(title, reply) do
    normalized_title = String.downcase(title)
    normalized_reply = String.downcase(reply)

    normalized_title == normalized_reply or
      (String.length(normalized_title) >= 20 and
         (String.starts_with?(normalized_reply, normalized_title) or
            String.starts_with?(normalized_title, normalized_reply)))
  end

  defp short_enough?(text) do
    String.length(text) <= @short_title_max_graphemes and
      length(words(text)) <= @short_title_max_words
  end

  defp first_words(text, count) do
    text
    |> words()
    |> Enum.take(count)
    |> Enum.join(" ")
  end

  defp words(text), do: String.split(text, ~r/\s+/u, trim: true)

  defp normalize_title(text) do
    stripped =
      text
      |> String.trim()
      |> String.replace(~r/\.+\z/u, "")
      |> String.trim()

    if stripped == "", do: @fallback_title, else: stripped
  end

  defp truncate_graphemes(text, max) when is_integer(max) and max > 0 do
    if String.length(text) <= max do
      text
    else
      text |> String.graphemes() |> Enum.take(max) |> Enum.join()
    end
  end

  defp bsky_url(uri) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, %{repo: repo, rkey: rkey}} -> "#{@bsky_profile_base}/#{repo}/post/#{rkey}"
      :error -> nil
    end
  end

  defp bsky_url(_uri), do: nil

  defp setting(%Settings{} = settings, key), do: Map.get(settings, key)

  defp setting(settings, key) when is_map(settings) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end

  defp setting(_settings, _key), do: nil

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
