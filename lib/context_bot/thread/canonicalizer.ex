defmodule ContextBot.Thread.Canonicalizer do
  @moduledoc """
  Produces deterministic, ancestor-only model context from a `getPostThread` response.

  Only nested `parent` values are traversed. Descendant replies are ignored. Bounded image embeds
  become structured model input, while video and excessive image counts are reported as unsupported.
  """

  alias ContextBot.ATProto.{ATURI, StrongRef}
  alias ContextBot.Thread.Media

  @thread_view_post "app.bsky.feed.defs#threadViewPost"
  @blocked_post "app.bsky.feed.defs#blockedPost"
  @not_found_post "app.bsky.feed.defs#notFoundPost"
  @post_record "app.bsky.feed.post"
  @mention_feature "app.bsky.richtext.facet#mention"
  @external_view "app.bsky.embed.external#view"
  @gallery_view "app.bsky.embed.gallery#view"
  @gallery_image_view "app.bsky.embed.gallery#viewImage"
  @images_view "app.bsky.embed.images#view"
  @record_view "app.bsky.embed.record#view"
  @record_with_media_view "app.bsky.embed.recordWithMedia#view"
  @video_view "app.bsky.embed.video#view"

  @type strong_ref :: %{required(String.t()) => String.t()}

  @type context :: %{
          bot_did: String.t(),
          invocation_uri: String.t(),
          notification_cid: String.t(),
          parent_height: pos_integer()
        }

  @type dry_run_context :: %{
          target_uri: String.t(),
          invocation_text: String.t(),
          parent_height: pos_integer()
        }

  @type result :: %{
          version: 2,
          text: String.t(),
          media: [map()],
          contains_video: boolean(),
          parent: strong_ref(),
          root: strong_ref(),
          current_cid: String.t()
        }

  @type question_only_result :: %{
          version: 2,
          text: String.t(),
          media: [map()],
          contains_video: boolean()
        }

  @type unsupported_result :: %{
          reason: :image_limit_exceeded,
          image_count: non_neg_integer(),
          canonical: result()
        }

  @spec build(map(), context()) ::
          {:ok, result()}
          | {:unsupported_media, unsupported_result()}
          | {:error, :target_unavailable | :invalid_thread}
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
         {:ok, ancestors} <-
           ancestors(Map.get(target, "parent"), parent_height, root["uri"], []) do
      canonical_result(ancestors, target_post, "invocation", nil, parent, root)
    else
      {:error, :edited_away} -> {:error, :target_unavailable}
      {:error, _reason} -> {:error, :invalid_thread}
    end
  end

  def build(%{"thread" => %{"$type" => type}}, _context)
      when type in [@blocked_post, @not_found_post],
      do: {:error, :target_unavailable}

  def build(_response, _context), do: {:error, :invalid_thread}

  @doc "Builds ancestor-only context for a local question beneath a selected public post."
  @spec build_dry_run(map(), dry_run_context()) ::
          {:ok, result()}
          | {:unsupported_media, unsupported_result()}
          | {:error, :target_unavailable | :invalid_thread}
  def build_dry_run(
        %{"thread" => %{"$type" => @thread_view_post} = target},
        %{
          target_uri: target_uri,
          invocation_text: invocation_text,
          parent_height: parent_height
        }
      )
      when is_binary(target_uri) and is_binary(invocation_text) and
             is_integer(parent_height) and parent_height > 0 do
    with {:ok, target_post} <- available_post(target),
         :ok <- matching_target?(target_post, target_uri),
         {:ok, parent} <- strong_ref(target_post),
         {:ok, root} <- root_ref(target_post.record, parent),
         {:ok, ancestors} <-
           ancestors(Map.get(target, "parent"), parent_height, root["uri"], []) do
      canonical_result(
        ancestors,
        target_post,
        "target",
        invocation_text,
        parent,
        root
      )
    else
      {:error, _reason} -> {:error, :invalid_thread}
    end
  end

  def build_dry_run(%{"thread" => %{"$type" => type}}, _context)
      when type in [@blocked_post, @not_found_post],
      do: {:error, :target_unavailable}

  def build_dry_run(_response, _context), do: {:error, :invalid_thread}

  @doc "Builds a local question subject with no parent, target post, or ancestors."
  @spec build_question_only(String.t()) ::
          {:ok, question_only_result()} | {:error, :invalid_input}
  def build_question_only(question) when is_binary(question) and question != "" do
    {:ok,
     %{
       version: 2,
       text: Enum.join(["CONTEXT_BOT_THREAD_V2", render_dry_run_invocation(question)], "\n\n"),
       media: [],
       contains_video: false
     }}
  end

  def build_question_only(_question), do: {:error, :invalid_input}

  defp available_post(%{
         "post" =>
           %{
             "uri" => uri,
             "cid" => cid,
             "author" => %{"did" => did} = author,
             "record" => %{"$type" => @post_record, "text" => text} = record
           } = post
       })
       when is_binary(text) do
    with {:ok, %{repo: ^did}} <- ATURI.parse(uri),
         {:ok, _reference} <- StrongRef.new(uri, cid) do
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
    else
      _invalid_author_uri_or_cid -> {:error, :invalid_post}
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
    case Map.fetch(record, "reply") do
      :error ->
        {:ok, parent}

      {:ok, %{"root" => %{"uri" => uri, "cid" => cid}}} ->
        StrongRef.new(uri, cid)

      {:ok, _invalid_reply} ->
        {:error, :invalid_root}
    end
  end

  defp ancestors(nil, remaining, root_uri, ancestors),
    do: {:ok, maybe_mark_truncated(ancestors, remaining, root_uri)}

  defp ancestors(_parent, 0, root_uri, ancestors),
    do: {:ok, maybe_mark_truncated(ancestors, 0, root_uri)}

  defp ancestors(%{"$type" => @thread_view_post} = parent, remaining, root_uri, ancestors) do
    with {:ok, post} <- available_post(parent),
         {:ok, _strong_ref} <- strong_ref(post) do
      ancestors(
        Map.get(parent, "parent"),
        remaining - 1,
        root_uri,
        [{:post, post} | ancestors]
      )
    end
  end

  defp ancestors(%{"$type" => @blocked_post}, _remaining, _root_uri, ancestors),
    do: {:ok, [:blocked | ancestors]}

  defp ancestors(%{"$type" => @not_found_post}, _remaining, _root_uri, ancestors),
    do: {:ok, [:unavailable | ancestors]}

  defp ancestors(%{"$type" => _unknown_type}, _remaining, _root_uri, ancestors),
    do: {:ok, [:unknown | ancestors]}

  defp ancestors(_invalid_parent, _remaining, _root_uri, _ancestors),
    do: {:error, :invalid_parent}

  defp maybe_mark_truncated([{:post, %{uri: root_uri}} | _rest] = ancestors, 0, root_uri),
    do: ancestors

  defp maybe_mark_truncated([{:post, _deepest} | _rest] = ancestors, 0, _root_uri),
    do: [:truncated | ancestors]

  defp maybe_mark_truncated(ancestors, _remaining, _root_uri), do: ancestors

  defp canonical_result(ancestors, target_post, target_kind, invocation_text, parent, root) do
    entries =
      Enum.map(ancestors, fn
        {:post, post} -> {:post, post, "ancestor"}
        placeholder -> placeholder
      end) ++ [{:post, target_post, target_kind}]

    with {:ok, scan} <- scan_entries(entries),
         media = Enum.take(scan.media, Media.max_images()),
         :ok <- Media.validate(media) do
      sections =
        if is_binary(invocation_text),
          do: scan.sections ++ [render_dry_run_invocation(invocation_text)],
          else: scan.sections

      canonical = %{
        version: 2,
        text: Enum.join(["CONTEXT_BOT_THREAD_V2" | sections], "\n\n"),
        media: media,
        contains_video: scan.video?,
        parent: parent,
        root: root,
        current_cid: target_post.cid
      }

      if length(scan.media) > Media.max_images() do
        {:unsupported_media,
         %{
           reason: :image_limit_exceeded,
           image_count: length(scan.media),
           canonical: canonical
         }}
      else
        {:ok, canonical}
      end
    else
      {:error, _reason} -> {:error, :invalid_thread}
    end
  end

  defp scan_entries(entries) do
    initial = %{sections: [], media: [], next_image_index: 1, video?: false}

    Enum.reduce_while(entries, {:ok, initial}, fn
      {:post, post, kind}, {:ok, state} ->
        case inspect_embed(post.embed, post.uri) do
          {:ok, embed} ->
            {images, next_image_index} =
              number_images(embed.images, state.next_image_index)

            embed_lines = embed.lines ++ render_image_lines(images)
            section = render_post(post, kind, embed_lines)

            {:cont,
             {:ok,
              %{
                sections: state.sections ++ [section],
                media: state.media ++ images,
                next_image_index: next_image_index,
                video?: state.video? or embed.video?
              }}}

          {:error, _reason} = error ->
            {:halt, error}
        end

      placeholder, {:ok, state} ->
        {:cont, {:ok, %{state | sections: state.sections ++ [render_placeholder(placeholder)]}}}
    end)
  end

  defp number_images(images, next_index) do
    numbered =
      images
      |> Enum.with_index(next_index)
      |> Enum.map(fn {image, index} -> Map.put(image, "index", index) end)

    {numbered, next_index + length(numbered)}
  end

  defp render_placeholder(:blocked), do: "[blocked ancestor]"
  defp render_placeholder(:unavailable), do: "[unavailable ancestor]"
  defp render_placeholder(:unknown), do: "[unknown ancestor]"
  defp render_placeholder(:truncated), do: "[ancestor chain truncated]"

  defp render_post(post, kind, embed_lines) do
    base = [
      "[#{kind}]",
      "Author: #{render_author(post)}",
      "URI: #{post.uri}",
      "Text:",
      post.text
    ]

    Enum.join(base ++ embed_lines, "\n")
  end

  defp render_dry_run_invocation(text), do: Enum.join(["[invocation]", "Text:", text], "\n")

  defp render_author(%{did: did, handle: nil}), do: did
  defp render_author(%{did: did, handle: handle}), do: "#{handle} (#{did})"

  defp inspect_embed(nil, _post_uri), do: empty_embed()

  defp inspect_embed(
         %{
           "$type" => @external_view,
           "external" => %{"title" => title, "uri" => uri, "description" => description}
         },
         _post_uri
       )
       when is_binary(title) and is_binary(uri) and uri != "" and is_binary(description) do
    lines =
      if title == "",
        do: ["External URI: #{uri}"],
        else: ["External link: #{title}", "External URI: #{uri}"]

    {:ok,
     %{
       lines: lines,
       images: [],
       video?: false
     }}
  end

  defp inspect_embed(%{"$type" => @record_view, "record" => %{"uri" => uri}}, _post_uri)
       when is_binary(uri) and uri != "" do
    {:ok, %{lines: ["Quoted post URI: #{uri}"], images: [], video?: false}}
  end

  defp inspect_embed(%{"$type" => @images_view, "images" => images}, post_uri)
       when is_list(images) do
    with {:ok, descriptors} <- validate_images(images, post_uri) do
      {:ok, %{lines: [], images: descriptors, video?: false}}
    end
  end

  defp inspect_embed(%{"$type" => @images_view}, _post_uri),
    do: {:error, :invalid_image_embed}

  defp inspect_embed(%{"$type" => @gallery_view, "items" => items}, post_uri)
       when is_list(items) do
    with {:ok, descriptors} <- validate_gallery_images(items, post_uri) do
      {:ok, %{lines: [], images: descriptors, video?: false}}
    end
  end

  defp inspect_embed(%{"$type" => @gallery_view}, _post_uri),
    do: {:error, :invalid_gallery_embed}

  defp inspect_embed(%{"$type" => @video_view}, _post_uri) do
    {:ok, %{lines: ["Video: present"], images: [], video?: true}}
  end

  defp inspect_embed(
         %{"$type" => @record_with_media_view, "record" => record, "media" => media},
         post_uri
       ) do
    with {:ok, record_result} <- inspect_record(record, post_uri),
         {:ok, media_result} <- inspect_media(media, post_uri) do
      {:ok, combine_embeds(record_result, media_result)}
    end
  end

  defp inspect_embed(%{"$type" => @record_with_media_view}, _post_uri),
    do: {:error, :invalid_media_embed}

  defp inspect_embed(_media_or_unknown, _post_uri), do: {:error, :invalid_media_embed}

  # AppView omits $type on recordWithMedia.record because that field is a lexicon
  # ref to app.bsky.embed.record#view, not a union. Media remains a typed union.
  defp inspect_record(%{"$type" => @record_view} = record, post_uri),
    do: inspect_embed(record, post_uri)

  defp inspect_record(%{"record" => %{"uri" => uri}} = record, post_uri)
       when is_binary(uri) and uri != "" and not is_map_key(record, "$type") do
    inspect_embed(Map.put(record, "$type", @record_view), post_uri)
  end

  defp inspect_record(_unknown_record, _post_uri), do: {:error, :invalid_media_embed}

  defp inspect_media(%{"$type" => type} = media, post_uri)
       when type in [@external_view, @gallery_view, @images_view, @video_view],
       do: inspect_embed(media, post_uri)

  defp inspect_media(_unknown_media, _post_uri), do: {:error, :invalid_media_embed}

  defp combine_embeds(left, right) do
    %{
      lines: left.lines ++ right.lines,
      images: left.images ++ right.images,
      video?: left.video? or right.video?
    }
  end

  defp empty_embed, do: {:ok, %{lines: [], images: [], video?: false}}

  defp validate_images(images, post_uri) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, descriptors} ->
      case validate_image(image, post_uri) do
        {:ok, descriptor} -> {:cont, {:ok, descriptors ++ [descriptor]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_gallery_images(images, post_uri) do
    Enum.reduce_while(images, {:ok, []}, fn
      %{"$type" => @gallery_image_view} = image, {:ok, descriptors} ->
        case validate_image(image, post_uri) do
          {:ok, descriptor} -> {:cont, {:ok, descriptors ++ [descriptor]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _unknown_item, {:ok, _descriptors} ->
        {:halt, {:error, :invalid_gallery_item}}
    end)
  end

  defp validate_image(image, post_uri), do: Media.descriptor(image, post_uri)

  defp render_image_lines([]), do: []

  defp render_image_lines(images) do
    ["Images:" | Enum.map(images, &render_image_line/1)]
  end

  defp render_image_line(%{"index" => index, "alt" => ""}),
    do: "- [image #{index}] Alt text: (none)"

  defp render_image_line(%{"index" => index, "alt" => alt}) do
    normalized_alt = String.replace(alt, ~r/\R/u, " ")
    "- [image #{index}] Alt text: #{normalized_alt}"
  end

  defp optional_nonempty(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end
end
