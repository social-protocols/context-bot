defmodule ContextBot.ATProto.ATURI do
  @moduledoc """
  Strict parsing for Bluesky post AT URIs.
  """

  @post_collection "app.bsky.feed.post"
  @post_uri ~r/\Aat:\/\/(did:[a-z0-9]+:[a-zA-Z0-9._:%-]+)\/app\.bsky\.feed\.post\/([^\/?#]+)\z/
  @rkey ~r/\A[a-zA-Z0-9_~.:-]{1,512}\z/

  @spec parse(binary()) ::
          {:ok, %{repo: binary(), collection: binary(), rkey: binary()}} | :error
  def parse(uri) when is_binary(uri) do
    case Regex.run(@post_uri, uri) do
      [_, repo, rkey] when rkey not in [".", ".."] ->
        if Regex.match?(@rkey, rkey) do
          {:ok, %{repo: repo, collection: @post_collection, rkey: rkey}}
        else
          :error
        end

      nil ->
        :error

      _ ->
        :error
    end
  end

  def parse(_uri), do: :error
end
