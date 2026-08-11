defmodule ContextBot.LiveRun.InvocationPost do
  @moduledoc """
  Resolves and validates one operator-selected public Bluesky invocation post.
  """

  alias ContextBot.ATProto.PublicClient
  alias ContextBot.DryRun.PostReference
  alias ContextBot.Mentions.Validator
  alias ContextBot.Settings

  @thread_view_post "app.bsky.feed.defs#threadViewPost"
  @blocked_post "app.bsky.feed.defs#blockedPost"
  @not_found_post "app.bsky.feed.defs#notFoundPost"
  @mention_feature "app.bsky.richtext.facet#mention"
  @maximum_receipt_bytes 65_536

  @type receipt :: %{
          uri: String.t(),
          cid: String.t(),
          actor_did: String.t(),
          actor_handle: String.t() | nil,
          invocation_text: String.t(),
          raw: map()
        }

  @spec resolve(String.t(), module()) :: {:ok, String.t()} | {:error, term()}
  def resolve(reference, resolver \\ PublicClient),
    do: PostReference.normalize(reference, resolver)

  @spec fetch(String.t(), Settings.t(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def fetch(uri, settings, options \\ [])

  def fetch(uri, %Settings{} = settings, options)
      when is_binary(uri) and is_list(options) do
    client = Keyword.get(options, :client, PublicClient)

    with {:ok, status, _headers, body} when status in 200..299 <-
           client.get_post_thread(uri, settings.thread_parent_height),
         {:ok, post} <- selected_post(body, uri),
         {:ok, validated} <- Validator.validate(validation_notification(post), settings.bot_did),
         {:ok, question} <- question_without_bot_mentions(post["record"], settings.bot_did),
         {:ok, raw} <- bounded_receipt(post) do
      {:ok,
       %{
         uri: validated.uri,
         cid: validated.cid,
         actor_did: validated.actor_did,
         actor_handle: validated.actor_handle,
         invocation_text: question,
         raw: raw
       }}
    else
      {:ok, _status, _headers, _body} -> {:error, :invalid_post}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_post}
    end
  rescue
    _invalid_response -> {:error, :invalid_post}
  catch
    _kind, _invalid_response -> {:error, :invalid_post}
  end

  def fetch(_uri, _settings, _options), do: {:error, :invalid_input}

  defp selected_post(
         %{
           "thread" => %{
             "$type" => @thread_view_post,
             "post" => %{"uri" => uri} = post
           }
         },
         uri
       ),
       do: {:ok, post}

  defp selected_post(%{"thread" => %{"$type" => type}}, _uri)
       when type in [@blocked_post, @not_found_post],
       do: {:error, :target_unavailable}

  defp selected_post(_body, _uri), do: {:error, :invalid_post}

  defp validation_notification(post) do
    %{
      "reason" => "mention",
      "uri" => Map.get(post, "uri"),
      "cid" => Map.get(post, "cid"),
      "author" => Map.get(post, "author"),
      "record" => Map.get(post, "record")
    }
  end

  defp question_without_bot_mentions(%{"text" => text, "facets" => facets}, bot_did)
       when is_binary(text) and is_list(facets) and is_binary(bot_did) do
    with {:ok, ranges} <- mention_ranges(facets, text, bot_did),
         question when is_binary(question) <- remove_ranges(text, ranges),
         true <- String.valid?(question),
         normalized when normalized != "" <- normalize_question(question) do
      {:ok, normalized}
    else
      {:error, reason} -> {:error, reason}
      _empty_or_invalid -> {:error, :missing_question}
    end
  end

  defp question_without_bot_mentions(_record, _bot_did), do: {:error, :invalid_post}

  defp mention_ranges(facets, text, bot_did) do
    facets
    |> Enum.filter(&targets_bot?(&1, bot_did))
    |> Enum.reduce_while({:ok, []}, fn facet, {:ok, ranges} ->
      case mention_range(facet, text) do
        {:ok, range} -> {:cont, {:ok, [range | ranges]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> require_ranges()
  end

  defp require_ranges({:ok, []}), do: {:error, :missing_mention_facet}

  defp require_ranges({:ok, ranges}) do
    sorted = Enum.sort_by(ranges, &elem(&1, 0))

    if overlapping?(sorted),
      do: {:error, :invalid_mention_range},
      else: {:ok, sorted}
  end

  defp require_ranges(error), do: error

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

  defp mention_range(
         %{"index" => %{"byteStart" => first, "byteEnd" => last}},
         text
       )
       when is_integer(first) and is_integer(last) and first >= 0 and first < last and
              last <= byte_size(text) do
    prefix = binary_part(text, 0, first)
    mention = binary_part(text, first, last - first)
    suffix = binary_part(text, last, byte_size(text) - last)

    if String.valid?(prefix) and String.valid?(mention) and String.valid?(suffix) and
         String.starts_with?(mention, "@") and not Regex.match?(~r/\s/u, mention) do
      {:ok, {first, last}}
    else
      {:error, :invalid_mention_range}
    end
  end

  defp mention_range(_facet, _text), do: {:error, :invalid_mention_range}

  defp remove_ranges(text, ranges) do
    ranges
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(text, fn {first, last}, current ->
      prefix = binary_part(current, 0, first)
      suffix = binary_part(current, last, byte_size(current) - last)
      prefix <> suffix
    end)
  end

  defp normalize_question(question) do
    question
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp bounded_receipt(post) do
    raw = %{"source" => "local_live_demo", "post" => post}

    case Jason.encode(raw) do
      {:ok, encoded} when byte_size(encoded) <= @maximum_receipt_bytes -> {:ok, raw}
      {:ok, _oversized} -> {:error, :raw_notification_too_large}
      {:error, _invalid} -> {:error, :invalid_post}
    end
  end
end
