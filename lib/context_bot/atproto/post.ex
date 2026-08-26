defmodule ContextBot.ATProto.Post do
  @moduledoc """
  Builds the exact Bluesky reply record persisted before publication.
  """

  alias ContextBot.ATProto.StrongRef

  @post_type "app.bsky.feed.post"
  @link_label "full response"
  @link_suffix " (full response)"

  @doc "Visible label used as a standalone full-response post."
  @spec link_label() :: String.t()
  def link_label, do: @link_label

  @doc "Suffix appended to a compact reply when the link fits in the same post."
  @spec link_suffix() :: String.t()
  def link_suffix, do: @link_suffix

  @spec build(binary(), String.t() | nil, map(), map() | nil, DateTime.t()) ::
          {:ok, map()}
          | {:error, :invalid_parent | :invalid_root | :invalid_text | :invalid_created_at}
  def build(text, reader_url, parent_ref, root_ref, created_at)
      when is_binary(text) and is_struct(created_at, DateTime) do
    {published_text, link_byte_start} = publish_text(text, reader_url)
    compose(published_text, reader_url, link_byte_start, parent_ref, root_ref, created_at)
  end

  def build(text, _reader_url, _parent_ref, _root_ref, _created_at) when not is_binary(text),
    do: {:error, :invalid_text}

  def build(_text, _reader_url, _parent_ref, _root_ref, _created_at),
    do: {:error, :invalid_created_at}

  @doc """
  Builds a post whose entire text is the faceted full-response link.
  """
  @spec build_link_only(String.t(), map(), map() | nil, DateTime.t()) ::
          {:ok, map()}
          | {:error, :invalid_parent | :invalid_root | :invalid_created_at}
  def build_link_only(reader_url, parent_ref, root_ref, created_at)
      when is_binary(reader_url) and is_struct(created_at, DateTime) do
    compose(@link_label, reader_url, 0, parent_ref, root_ref, created_at)
  end

  defp compose(text, reader_url, link_byte_start, parent_ref, root_ref, created_at) do
    with {:ok, parent} <- validate_ref(parent_ref, :invalid_parent),
         {:ok, root} <- validate_root(root_ref, parent) do
      base_record = %{
        "$type" => @post_type,
        "text" => text,
        "createdAt" => DateTime.to_iso8601(created_at),
        "reply" => %{"parent" => parent, "root" => root}
      }

      record =
        if is_binary(reader_url) and is_integer(link_byte_start) do
          Map.put(base_record, "facets", link_facets(reader_url, link_byte_start))
        else
          base_record
        end

      {:ok, record}
    end
  end

  defp publish_text(text, nil), do: {text, nil}

  defp publish_text(text, reader_url) when is_binary(reader_url) do
    {text <> @link_suffix, byte_size(text) + byte_size(" (")}
  end

  defp link_facets(reader_url, byte_start)
       when is_binary(reader_url) and is_integer(byte_start) do
    [
      %{
        "index" => %{
          "byteStart" => byte_start,
          "byteEnd" => byte_start + byte_size(@link_label)
        },
        "features" => [
          %{
            "$type" => "app.bsky.richtext.facet#link",
            "uri" => reader_url
          }
        ]
      }
    ]
  end

  defp validate_root(nil, parent), do: {:ok, parent}
  defp validate_root(root, _parent), do: validate_ref(root, :invalid_root)

  defp validate_ref(%{"uri" => uri, "cid" => cid}, error) do
    case StrongRef.new(uri, cid) do
      {:ok, reference} -> {:ok, reference}
      {:error, _reason} -> {:error, error}
    end
  end

  defp validate_ref(_reference, error), do: {:error, error}
end
