defmodule ContextBot.Mentions.Validator do
  @moduledoc """
  Validates direct-mention notifications before they become durable receipts.
  """

  alias ContextBot.ATProto.ATURI

  @post_type "app.bsky.feed.post"
  @mention_feature "app.bsky.richtext.facet#mention"

  @spec validate(map(), String.t()) ::
          {:ok,
           %{
             uri: String.t(),
             cid: String.t(),
             actor_did: String.t(),
             actor_handle: String.t() | nil,
             raw: map()
           }}
          | {:error, atom()}
  def validate(notification, bot_did) when is_map(notification) and is_binary(bot_did) do
    with :ok <- mention_reason(notification),
         {:ok, record} <- post_record(notification),
         {:ok, actor_did, actor_handle} <- author(notification, bot_did),
         {:ok, uri} <- post_uri(notification, actor_did),
         {:ok, cid} <- cid(notification),
         :ok <- mentions_bot?(record, bot_did) do
      {:ok,
       %{
         uri: uri,
         cid: cid,
         actor_did: actor_did,
         actor_handle: actor_handle,
         raw: notification
       }}
    end
  end

  def validate(_notification, _bot_did), do: {:error, :invalid_notification}

  defp mention_reason(%{"reason" => "mention"}), do: :ok
  defp mention_reason(_notification), do: {:error, :not_a_mention}

  defp post_record(%{"record" => %{"$type" => @post_type} = record}), do: {:ok, record}
  defp post_record(_notification), do: {:error, :not_a_post}

  defp author(%{"author" => %{"did" => did} = author}, bot_did)
       when is_binary(did) and did != "" and did != bot_did do
    {:ok, did, optional_string(author, "handle")}
  end

  defp author(_notification, _bot_did), do: {:error, :invalid_author}

  defp post_uri(%{"uri" => uri}, actor_did) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, %{repo: ^actor_did}} -> {:ok, uri}
      _ -> {:error, :invalid_post_uri}
    end
  end

  defp post_uri(_notification, _actor_did), do: {:error, :invalid_post_uri}

  defp cid(%{"cid" => cid}) when is_binary(cid) and cid != "", do: {:ok, cid}
  defp cid(_notification), do: {:error, :missing_cid}

  defp mentions_bot?(%{"facets" => facets}, bot_did) when is_list(facets) do
    if Enum.any?(facets, &mention_facet?(&1, bot_did)) do
      :ok
    else
      {:error, :missing_mention_facet}
    end
  end

  defp mentions_bot?(_record, _bot_did), do: {:error, :missing_mention_facet}

  defp mention_facet?(%{"features" => features}, bot_did) when is_list(features) do
    Enum.any?(features, fn
      %{"$type" => @mention_feature, "did" => ^bot_did} -> true
      _ -> false
    end)
  end

  defp mention_facet?(_facet, _bot_did), do: false

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
