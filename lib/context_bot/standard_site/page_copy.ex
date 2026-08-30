defmodule ContextBot.StandardSite.PageCopy do
  @moduledoc """
  Builds Standard Reader title, description, and responding-to copy from the invoking post.

  New full-response documents only. Existing published records are not rewritten
  by the publication path.
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
          invocation_uri: String.t() | nil,
          invoker_handle: String.t() | nil,
          parent_handle: String.t() | nil
        }

  @doc "Card-length cap for `description`. The lexicon hard cap is 3000 graphemes."
  @spec description_max_graphemes() :: pos_integer()
  def description_max_graphemes, do: @description_card_graphemes

  @doc """
  Extracts the invoking-post text as written, optional parent URI, and handles.

  Mentions are kept. Missing parent or handle data is omitted. Document create
  must not fail for that reason.
  """
  @spec subject(Invocation.t() | map(), settings()) :: subject()
  def subject(invocation, _settings) do
    record = invocation_record(invocation)
    thread = field(invocation, :raw_thread)
    notification = field(invocation, :raw_notification)

    %{
      asked_text: raw_invocation_text(record, invocation),
      parent_uri: parent_uri(record),
      invocation_uri: field(invocation, :invocation_uri),
      invoker_handle: invoker_handle(thread, notification, invocation),
      parent_handle: parent_handle(thread)
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
  One responding-to line placed above the Claude continue link.

  Uses a public bsky.app **post** URL for the invocation and, when the
  invocation is a reply with a parseable parent URI, for the parent. Handles
  from thread or notification records are preferred in both the link text and
  the profile segment; a missing handle falls back to the AT-URI repo. A
  missing or unusable parent uses the root sentence. Create must not fail.
  """
  @spec asked_markdown(content()) :: String.t()
  def asked_markdown(content) when is_map(content) do
    invocation_uri = field(content, :invocation_uri)
    parent_uri = parseable_uri(field(content, :parent_uri))
    invoker = actor_ref(field(content, :invoker_handle), invocation_uri)
    parent = actor_ref(field(content, :parent_handle), parent_uri)

    cond do
      match?({_, url} when is_binary(url), invoker) and
          match?({_, url} when is_binary(url), parent) ->
        {invoker_label, invoker_url} = invoker
        {parent_label, parent_url} = parent

        "Responding to [@#{invoker_label}](#{invoker_url})'s reply to [@#{parent_label}](#{parent_url})'s post."

      match?({_, url} when is_binary(url), invoker) ->
        {invoker_label, invoker_url} = invoker
        "Responding to [@#{invoker_label}](#{invoker_url})'s post."

      true ->
        ""
    end
  end

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

  defp parent_uri(record), do: parseable_uri(parent_uri_raw(record))

  defp parent_uri_raw(%{"reply" => %{"parent" => %{"uri" => uri}}}) when is_binary(uri), do: uri
  defp parent_uri_raw(_record), do: nil

  defp parseable_uri(uri) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, _parsed} -> uri
      :error -> nil
    end
  end

  defp parseable_uri(_uri), do: nil

  defp invoker_handle(thread, notification, invocation) do
    usable_handle(
      thread_author_handle(thread) ||
        notification_author_handle(notification) ||
        field(invocation, :actor_handle)
    )
  end

  defp parent_handle(thread), do: usable_handle(thread_parent_author_handle(thread))

  defp thread_author_handle(%{"thread" => %{"post" => %{"author" => author}}}),
    do: author_handle(author)

  defp thread_author_handle(_thread), do: nil

  defp thread_parent_author_handle(%{
         "thread" => %{"parent" => %{"post" => %{"author" => author}}}
       }),
       do: author_handle(author)

  defp thread_parent_author_handle(_thread), do: nil

  defp notification_author_handle(%{"author" => author}), do: author_handle(author)
  defp notification_author_handle(_notification), do: nil

  defp author_handle(author) when is_map(author) do
    case field(author, :handle) do
      handle when is_binary(handle) -> String.trim(handle)
      _missing -> nil
    end
  end

  defp author_handle(_author), do: nil

  defp actor_ref(handle, uri) do
    case {usable_handle(handle), parsed_post(uri)} do
      {label, %{repo: _repo, rkey: rkey}} when is_binary(label) ->
        {label, "#{@bsky_profile_base}/#{label}/post/#{rkey}"}

      {_missing, %{repo: repo, rkey: rkey}} ->
        {repo, "#{@bsky_profile_base}/#{repo}/post/#{rkey}"}

      {_handle, _unusable} ->
        nil
    end
  end

  defp parsed_post(uri) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, parsed} -> parsed
      :error -> nil
    end
  end

  defp parsed_post(_uri), do: nil

  defp usable_handle(handle) when is_binary(handle) do
    trimmed = String.trim(handle)

    if trimmed != "" and String.contains?(trimmed, ".") and
         String.match?(trimmed, ~r/\A[a-zA-Z0-9.-]+\z/) do
      trimmed
    end
  end

  defp usable_handle(_handle), do: nil

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
      |> Enum.reduce_while({"", 0}, &take_title_word(&1, &2, cap))
      |> elem(0)
    end
  end

  defp take_title_word(word, {acc, count}, cap) do
    next = if acc == "", do: word, else: acc <> " " <> word
    next_count = count + 1

    if String.length(next) <= cap and next_count <= @title_max_words do
      {:cont, {next, next_count}}
    else
      {:halt, {acc, count}}
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

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
