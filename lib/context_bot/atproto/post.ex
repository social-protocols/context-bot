defmodule ContextBot.ATProto.Post do
  @moduledoc """
  Builds the exact Bluesky reply record persisted before publication.
  """

  alias ContextBot.ATProto.StrongRef

  @post_type "app.bsky.feed.post"

  @spec build(binary(), String.t() | nil, map(), map() | nil, DateTime.t()) ::
          {:ok, map()}
          | {:error, :invalid_parent | :invalid_root | :invalid_text | :invalid_created_at}
  def build(text, reader_url, parent_ref, root_ref, created_at)
      when is_binary(text) and is_struct(created_at, DateTime) do
    with {:ok, parent} <- validate_ref(parent_ref, :invalid_parent),
         {:ok, root} <- validate_root(root_ref, parent) do
      base_record = %{
        "$type" => @post_type,
        "text" => build_text(text, reader_url),
        "createdAt" => DateTime.to_iso8601(created_at),
        "reply" => %{"parent" => parent, "root" => root}
      }

      record =
        if reader_url do
          Map.put(base_record, "facets", build_facets(text, reader_url))
        else
          base_record
        end

      {:ok, record}
    end
  end

  def build(text, _reader_url, _parent_ref, _root_ref, _created_at) when not is_binary(text),
    do: {:error, :invalid_text}

  def build(_text, _reader_url, _parent_ref, _root_ref, _created_at),
    do: {:error, :invalid_created_at}

  defp build_text(text, nil), do: text

  defp build_text(text, reader_url) when is_binary(reader_url) do
    text <> " (full response)"
  end

  defp build_facets(text, reader_url) when is_binary(reader_url) do
    # Calculate byte position for the link text
    base_text_bytes = byte_size(text)
    link_text = " (full response)"
    byte_start = base_text_bytes + byte_size(" (")
    byte_end = byte_start + byte_size("full response")

    [
      %{
        "index" => %{
          "byteStart" => byte_start,
          "byteEnd" => byte_end
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
