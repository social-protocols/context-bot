defmodule ContextBot.ATProto.ATURI do
  @moduledoc """
  Strict parsing for Bluesky post AT URIs.
  """

  @post_collection "app.bsky.feed.post"
  @post_uri ~r/\Aat:\/\/(did:[^\/]+)\/app\.bsky\.feed\.post\/([^\/?#]+)\z/
  @did ~r/\Adid:[a-z]+:(?:[a-zA-Z0-9._:-]|%[a-fA-F0-9]{2})*(?:[a-zA-Z0-9._-]|%[a-fA-F0-9]{2})\z/
  @rkey ~r/\A[a-zA-Z0-9_~.:-]{1,512}\z/

  @spec parse(binary()) ::
          {:ok, %{repo: binary(), collection: binary(), rkey: binary()}} | :error
  def parse(uri) when is_binary(uri) do
    case Regex.run(@post_uri, uri) do
      [_, repo, rkey] when rkey not in [".", ".."] ->
        if valid_did?(repo) and Regex.match?(@rkey, rkey) do
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

  defp valid_did?(did), do: byte_size(did) <= 2_048 and Regex.match?(@did, did)
end
