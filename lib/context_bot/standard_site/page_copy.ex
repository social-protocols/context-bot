defmodule ContextBot.StandardSite.PageCopy do
  @moduledoc """
  Builds Standard Reader title, description, and Asked-block copy from the invoking post.

  New full-response documents only. Existing published records are not rewritten.
  """

  alias ContextBot.ATProto.ATURI
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @bsky_profile_base "https://bsky.app/profile"
  @title_max_graphemes 80
  @title_max_words 12
  @title_lexicon_graphemes 500
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
  Extracts the invoking-post text as written and an optional parent URI.

  Mentions are kept. Missing parent data is omitted. Document create must not
  fail for that reason.
  """
  @spec subject(Invocation.t() | map(), settings()) :: subject()
  def subject(invocation, _settings) do
    record = invocation_record(invocation)

    %{
      asked_text: raw_invocation_text(record, invocation),
      parent_uri: parent_uri(record),
      invocation_uri: field(invocation, :invocation_uri)
    }
  end

  @doc """
  Short Title Case summary of the topic or question.

  Prefers a usable model `document_title` when present. Otherwise uses the first
  sentence of the raw invocation (mentions kept). Never uses a six-word slice,
  mention-stripped remnants, or the invocation TID.
  """
  @spec title(content()) :: String.t()
  def title(content) when is_map(content) do
    asked = asked_text(content)
    reply = optional_text(content, :selected_reply)
    model_title = optional_text(content, :document_title)

    cond do
      usable_model_title?(model_title, reply) ->
        normalize_title(model_title)

      asked == "" ->
        @fallback_title

      true ->
        asked
        |> first_sentence()
        |> truncate_title()
        |> normalize_title()
    end
  end

  @doc "Optional excerpt: invocation text as written, capped for a Reader card."
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

  Uses the invoking-post text as written. Includes a public bsky.app link to the
  invoking post. A parent link is added only when the invocation is a reply and
  that URI is parseable.
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

  defp raw_invocation_text(%{"text" => text}, _invocation) when is_binary(text) do
    String.trim(text)
  end

  defp raw_invocation_text(_record, invocation) do
    case field(invocation, :invocation_text) do
      text when is_binary(text) -> String.trim(text)
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

  defp first_sentence(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/\A(.+?[.!?])(?:\s|\z)/us, trimmed) do
      [_, sentence] -> String.trim(sentence)
      _missing -> trimmed
    end
  end

  defp truncate_title(text) do
    cap = min(@title_max_graphemes, @title_lexicon_graphemes)

    if String.length(text) <= cap do
      text
    else
      text
      |> words()
      |> Enum.reduce_while({"", 0}, fn word, {acc, count} ->
        next = if acc == "", do: word, else: acc <> " " <> word
        next_count = count + 1

        if String.length(next) <= cap and next_count <= @title_max_words do
          {:cont, {next, next_count}}
        else
          {:halt, {acc, count}}
        end
      end)
      |> elem(0)
    end
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

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
