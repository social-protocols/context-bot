defmodule ContextBot.ATProto.Post do
  @moduledoc """
  Builds the exact Bluesky reply record persisted before publication.
  """

  alias ContextBot.ATProto.StrongRef

  @post_type "app.bsky.feed.post"

  @spec build(binary(), map(), map() | nil, DateTime.t()) ::
          {:ok, map()}
          | {:error, :invalid_parent | :invalid_root | :invalid_text | :invalid_created_at}
  def build(text, parent_ref, root_ref, created_at)
      when is_binary(text) and is_struct(created_at, DateTime) do
    with {:ok, parent} <- validate_ref(parent_ref, :invalid_parent),
         {:ok, root} <- validate_root(root_ref, parent) do
      {:ok,
       %{
         "$type" => @post_type,
         "text" => text,
         "createdAt" => DateTime.to_iso8601(created_at),
         "reply" => %{"parent" => parent, "root" => root}
       }}
    end
  end

  def build(text, _parent_ref, _root_ref, _created_at) when not is_binary(text),
    do: {:error, :invalid_text}

  def build(_text, _parent_ref, _root_ref, _created_at), do: {:error, :invalid_created_at}

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
