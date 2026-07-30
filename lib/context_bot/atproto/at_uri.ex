defmodule ContextBot.ATProto.ATURI do
  @moduledoc """
  Strict parsing for Bluesky post AT URIs.
  """

  @post_collection "app.bsky.feed.post"
  @post_uri ~r/\Aat:\/\/(did:[a-z0-9]+:[a-zA-Z0-9._:%-]+)\/app\.bsky\.feed\.post\/([^\/?#]+)\z/

  @spec parse(binary()) ::
          {:ok, %{repo: binary(), collection: binary(), rkey: binary()}} | :error
  def parse(uri) when is_binary(uri) do
    case Regex.run(@post_uri, uri) do
      [_, repo, rkey] -> {:ok, %{repo: repo, collection: @post_collection, rkey: rkey}}
      nil -> :error
    end
  end

  def parse(_uri), do: :error
end
