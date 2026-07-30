defmodule ContextBot.Thread.Canonicalizer do
  @moduledoc """
  Produces deterministic, ancestor-only model context from a `getPostThread` response.

  Only nested `parent` values are traversed. Descendant replies and media content are ignored.
  """

  alias ContextBot.ATProto.StrongRef

  @thread_view_post "app.bsky.feed.defs#threadViewPost"
  @blocked_post "app.bsky.feed.defs#blockedPost"
  @not_found_post "app.bsky.feed.defs#notFoundPost"
  @post_record "app.bsky.feed.post"
  @mention_feature "app.bsky.richtext.facet#mention"
  @external_view "app.bsky.embed.external#view"
  @record_view "app.bsky.embed.record#view"
  @record_with_media_view "app.bsky.embed.recordWithMedia#view"

  @type strong_ref :: %{required(String.t()) => String.t()}

  @type context :: %{
          bot_did: String.t(),
          invocation_uri: String.t(),
          notification_cid: String.t(),
          parent_height: pos_integer()
        }

  @type result :: %{
          version: 1,
          text: String.t(),
          parent: strong_ref(),
          root: strong_ref(),
          current_cid: String.t()
        }

  @spec build(map(), context()) ::
          {:ok, result()} | {:error, :target_unavailable | :invalid_thread}
  def build(
        %{"thread" => %{"$type" => @thread_view_post} = target},
        %{
          bot_did: bot_did,
          invocation_uri: invocation_uri,
          notification_cid: notification_cid,
          parent_height: parent_height
        }
      )
      when is_binary(bot_did) and is_binary(invocation_uri) and
             is_binary(notification_cid) and is_integer(parent_height) and parent_height > 0 do
    with {:ok, target_post} <- available_post(target),
         :ok <- matching_target?(target_post, invocation_uri),
         :ok <- current_mention?(target_post, notification_cid, bot_did),
         {:ok, parent} <- strong_ref(target_post),
         {:ok, root} <- root_ref(target_post.record, parent),
         {:ok, ancestors} <- ancestors(Map.get(target, "parent"), parent_height, []) do
      sections =
        Enum.map(ancestors, &render_ancestor/1) ++ [render_post(target_post, "invocation")]

      {:ok,
       %{
         version: 1,
         text: Enum.join(["CONTEXT_BOT_THREAD_V1" | sections], "\n\n"),
         parent: parent,
         root: root,
         current_cid: target_post.cid
       }}
    else
      {:error, :edited_away} -> {:error, :target_unavailable}
      {:error, _reason} -> {:error, :invalid_thread}
    end
  end

  def build(%{"thread" => %{"$type" => type}}, _context)
      when type in [@blocked_post, @not_found_post],
      do: {:error, :target_unavailable}

  def build(_response, _context), do: {:error, :invalid_thread}

  defp available_post(%{"post" => post}) when is_map(post) do
    case post do
      %{
        "uri" => uri,
        "cid" => cid,
        "author" => %{"did" => did} = author,
        "record" => %{"$type" => @post_record, "text" => text} = record
      }
      when is_binary(uri) and is_binary(cid) and cid != "" and is_binary(did) and did != "" and
             is_binary(text) ->
        {:ok,
         %{
           uri: uri,
           cid: cid,
           did: did,
           handle: optional_nonempty(author, "handle"),
           text: text,
           record: record,
           embed: Map.get(post, "embed")
         }}

      _invalid_post ->
        {:error, :invalid_post}
    end
  end

  defp available_post(_view), do: {:error, :invalid_post}

  defp matching_target?(%{uri: invocation_uri}, invocation_uri), do: :ok
  defp matching_target?(_post, _invocation_uri), do: {:error, :wrong_target}

  defp current_mention?(%{cid: cid}, cid, _bot_did), do: :ok

  defp current_mention?(%{record: record}, _notification_cid, bot_did) do
    if directly_mentions?(record, bot_did),
      do: :ok,
      else: {:error, :edited_away}
  end

  defp directly_mentions?(%{"facets" => facets}, bot_did) when is_list(facets) do
    Enum.any?(facets, fn
      %{"features" => features} when is_list(features) ->
        Enum.any?(features, fn
          %{"$type" => @mention_feature, "did" => ^bot_did} -> true
          _feature -> false
        end)

      _facet ->
        false
    end)
  end

  defp directly_mentions?(_record, _bot_did), do: false

  defp strong_ref(%{uri: uri, cid: cid}), do: StrongRef.new(uri, cid)

  defp root_ref(record, parent) do
    case get_in(record, ["reply", "root"]) do
      nil -> {:ok, parent}
      %{"uri" => uri, "cid" => cid} -> StrongRef.new(uri, cid)
      _invalid_root -> {:error, :invalid_root}
    end
  end

  defp ancestors(nil, _remaining, ancestors), do: {:ok, ancestors}

  defp ancestors(_parent, 0, ancestors),
    do: {:ok, [:truncated | ancestors]}

  defp ancestors(%{"$type" => @thread_view_post} = parent, remaining, ancestors) do
    with {:ok, post} <- available_post(parent),
         {:ok, _strong_ref} <- strong_ref(post) do
      ancestors(Map.get(parent, "parent"), remaining - 1, [{:post, post} | ancestors])
    end
  end

  defp ancestors(%{"$type" => @blocked_post}, _remaining, ancestors),
    do: {:ok, [:blocked | ancestors]}

  defp ancestors(%{"$type" => @not_found_post}, _remaining, ancestors),
    do: {:ok, [:unavailable | ancestors]}

  defp ancestors(%{"$type" => _unknown_type}, _remaining, ancestors),
    do: {:ok, [:unknown | ancestors]}

  defp ancestors(_invalid_parent, _remaining, _ancestors), do: {:error, :invalid_parent}

  defp render_ancestor({:post, post}), do: render_post(post, "ancestor")
  defp render_ancestor(:blocked), do: "[blocked ancestor]"
  defp render_ancestor(:unavailable), do: "[unavailable ancestor]"
  defp render_ancestor(:unknown), do: "[unknown ancestor]"
  defp render_ancestor(:truncated), do: "[ancestor chain truncated]"

  defp render_post(post, kind) do
    base = [
      "[#{kind}]",
      "Author: #{render_author(post)}",
      "URI: #{post.uri}",
      "Text:",
      post.text
    ]

    Enum.join(base ++ embed_lines(post.embed), "\n")
  end

  defp render_author(%{did: did, handle: nil}), do: did
  defp render_author(%{did: did, handle: handle}), do: "#{handle} (#{did})"

  defp embed_lines(%{
         "$type" => @external_view,
         "external" => %{"title" => title, "uri" => uri}
       })
       when is_binary(title) and title != "" and is_binary(uri) and uri != "" do
    ["External link: #{title}", "External URI: #{uri}"]
  end

  defp embed_lines(%{"$type" => @record_view, "record" => %{"uri" => uri}})
       when is_binary(uri) and uri != "",
       do: ["Quoted post URI: #{uri}"]

  defp embed_lines(%{"$type" => @record_with_media_view} = embed) do
    embed_lines(Map.get(embed, "record")) ++ embed_lines(Map.get(embed, "media"))
  end

  defp embed_lines(_media_or_unknown), do: []

  defp optional_nonempty(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end
end
