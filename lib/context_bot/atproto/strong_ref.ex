defmodule ContextBot.ATProto.StrongRef do
  @moduledoc """
  Validated `com.atproto.repo.strongRef` values.
  """

  alias ContextBot.ATProto.ATURI

  @spec new(binary(), binary()) :: {:ok, map()} | {:error, :invalid_uri | :invalid_cid}
  def new(uri, cid) when is_binary(cid) and byte_size(cid) > 0 do
    case ATURI.parse(uri) do
      {:ok, _parsed} -> {:ok, %{"uri" => uri, "cid" => cid}}
      :error -> {:error, :invalid_uri}
    end
  end

  def new(uri, _cid) when is_binary(uri), do: {:error, :invalid_cid}
  def new(_uri, _cid), do: {:error, :invalid_uri}
end
