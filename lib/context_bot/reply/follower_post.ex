defmodule ContextBot.Reply.FollowerPost do
  @moduledoc """
  Builds one top-level follower-feed post after a successful thread reply.

  Followers do not see reply-only answers. This post quotes the canonical thread
  root (the claim the invoking question is about) and cards the Standard Reader
  URL so Bluesky can scrape the Reader OG once Tap has indexed the document. It
  never quotes the invoking mention or the bot's own reply.
  """

  alias ContextBot.ATProto.StrongRef
  alias ContextBot.StandardSite.{Document, PageCopy}
  alias ContextBot.Workflow.Invocation

  @post_type "app.bsky.feed.post"
  @record_with_media "app.bsky.embed.recordWithMedia"
  @embed_record "app.bsky.embed.record"
  @embed_external "app.bsky.embed.external"
  @link_facet "app.bsky.richtext.facet#link"
  @title_suffix " · Context Bot"
  @fallback_description "Context Bot research"
  @display_link_prefix_bytes 32

  @type build_error ::
          :ineligible
          | :invalid_root
          | :invalid_reader_url
          | :invalid_created_at

  @spec eligible?(Invocation.t()) :: boolean()
  def eligible?(%Invocation{} = invocation) do
    not invocation.dry_run and not invocation.no_reply and quoteable_root?(invocation) and
      match?({:ok, _url}, reader_url(invocation))
  end

  def eligible?(_invocation), do: false

  @spec build(Invocation.t(), DateTime.t()) :: {:ok, map()} | {:error, build_error()}
  def build(%Invocation{} = invocation, %DateTime{} = created_at) do
    with :ok <- accept(invocation),
         {:ok, root} <- root_ref(invocation),
         {:ok, url} <- reader_url(invocation) do
      text = display_link_text(url)

      {:ok,
       %{
         "$type" => @post_type,
         "text" => text,
         "createdAt" => DateTime.to_iso8601(created_at),
         "facets" => link_facets(url, text),
         "embed" => %{
           "$type" => @record_with_media,
           "record" => %{
             "$type" => @embed_record,
             "record" => root
           },
           "media" => %{
             "$type" => @embed_external,
             "external" => external_card(invocation, url)
           }
         }
       }}
    end
  end

  def build(_invocation, _created_at), do: {:error, :invalid_created_at}

  @spec reader_url(Invocation.t()) :: {:ok, String.t()} | {:error, :invalid_reader_url}
  def reader_url(%Invocation{} = invocation) do
    cond do
      https_url?(standard_reader_url(invocation)) ->
        {:ok, standard_reader_url(invocation)}

      standard_reader_url?(facet_or_stored_url(invocation)) ->
        {:ok, facet_or_stored_url(invocation)}

      true ->
        {:error, :invalid_reader_url}
    end
  end

  defp accept(%Invocation{} = invocation) do
    if eligible?(invocation), do: :ok, else: {:error, :ineligible}
  end

  defp quoteable_root?(%Invocation{} = invocation) do
    root_uri = invocation.root_uri
    root_cid = invocation.root_cid

    present?(root_uri) and present?(root_cid) and
      root_uri != invocation.invocation_uri and
      root_uri != invocation.reply_uri and
      root_uri != invocation.reply_part2_uri and
      root_uri != invocation.reply_part3_uri
  end

  defp root_ref(%Invocation{root_uri: uri, root_cid: cid}) do
    case StrongRef.new(uri, cid) do
      {:ok, reference} -> {:ok, reference}
      {:error, _reason} -> {:error, :invalid_root}
    end
  end

  defp external_card(invocation, url) do
    copy = page_copy(invocation)

    %{
      "uri" => url,
      "title" => card_title(copy),
      "description" => card_description(copy)
    }
    |> maybe_put_associated_refs(invocation)
  end

  defp maybe_put_associated_refs(external, invocation) do
    case associated_refs(invocation) do
      [] -> external
      refs -> Map.put(external, "associatedRefs", refs)
    end
  end

  defp associated_refs(%Invocation{} = invocation) do
    []
    |> maybe_add_ref(invocation.standard_site_document_uri, invocation.standard_site_document_cid)
    |> maybe_add_ref(
      invocation.standard_site_publication_uri,
      invocation.standard_site_publication_cid
    )
  end

  defp maybe_add_ref(refs, uri, cid) do
    cond do
      not present?(uri) or not present?(cid) ->
        refs

      not record_uri?(uri) ->
        refs

      true ->
        refs ++ [%{"uri" => uri, "cid" => cid}]
    end
  end

  defp record_uri?("at://" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [did, collection, rkey]
      when did != "" and collection != "" and rkey != "" ->
        String.starts_with?(did, "did:") and
          collection in ["site.standard.document", "site.standard.publication"]

      _other ->
        false
    end
  end

  defp record_uri?(_uri), do: false

  defp page_copy(%Invocation{} = invocation) do
    subject = PageCopy.subject(invocation, %{})

    %{
      asked_text: subject.asked_text,
      selected_reply: invocation.selected_reply,
      document_title: document_title(invocation)
    }
  end

  defp document_title(%Invocation{reply_validation: %{"document_title" => title}})
       when is_binary(title) and title != "",
       do: title

  defp document_title(_invocation), do: nil

  defp card_title(copy) do
    title = PageCopy.title(copy)

    if String.ends_with?(title, @title_suffix) do
      title
    else
      title <> @title_suffix
    end
  end

  defp card_description(copy) do
    case PageCopy.description(copy) do
      description when is_binary(description) and description != "" -> description
      _missing -> @fallback_description
    end
  end

  defp facet_or_stored_url(invocation) do
    facet_link_uri(invocation.reply_record) ||
      stored_reader_url(invocation.reply_part2_record) ||
      stored_reader_url(invocation.reply_part3_record)
  end

  defp standard_reader_url(%Invocation{standard_site_document_uri: uri}) do
    Document.reader_url_from_uri(uri)
  end

  defp standard_reader_url?("https://standard-reader.app/" <> rest) when rest != "", do: true
  defp standard_reader_url?(_url), do: false

  defp facet_link_uri(%{"facets" => facets}) when is_list(facets) do
    Enum.find_value(facets, &facet_feature_uri/1)
  end

  defp facet_link_uri(_record), do: nil

  defp facet_feature_uri(%{"features" => features}) when is_list(features) do
    Enum.find_value(features, fn
      %{"$type" => @link_facet, "uri" => uri} when is_binary(uri) and uri != "" -> uri
      _other -> nil
    end)
  end

  defp facet_feature_uri(_facet), do: nil

  defp stored_reader_url(%{"readerUrl" => url}) when is_binary(url) and url != "", do: url
  defp stored_reader_url(_record), do: nil

  defp display_link_text("https://" <> rest), do: shorten_display(rest)
  defp display_link_text("http://" <> rest), do: shorten_display(rest)
  defp display_link_text(url), do: shorten_display(url)

  defp shorten_display(text)
       when byte_size(text) <= @display_link_prefix_bytes + byte_size("..."),
       do: text

  defp shorten_display(text) do
    binary_part(text, 0, @display_link_prefix_bytes) <> "..."
  end

  defp link_facets(url, text) do
    [
      %{
        "index" => %{"byteStart" => 0, "byteEnd" => byte_size(text)},
        "features" => [%{"$type" => @link_facet, "uri" => url}]
      }
    ]
  end

  defp https_url?("https://" <> rest) when rest != "", do: true
  defp https_url?(_url), do: false

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
end
