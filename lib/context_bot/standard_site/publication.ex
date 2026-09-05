defmodule ContextBot.StandardSite.Publication do
  @moduledoc """
  Ensures the bot's Standard.site publication record exists.

  A publication is a one-time record that describes the publication source.
  It uses a stable rkey and persists for the lifetime of the bot.
  """

  alias ContextBot.ATProto.Client

  @collection "site.standard.publication"
  @publication_rkey "context-bot"
  @publication_url "https://getcontext.bot"
  @publication_name "Context Bot"

  @type result :: {:ok, %{uri: String.t(), cid: String.t() | nil}} | {:error, atom()}

  @doc """
  Ensures the publication record exists and returns its AT URI and recorded CID.

  This operation is idempotent. If the record already exists with matching identity
  (`$type`, `url`, and `name`), returns success even when `createdAt` differs. If it
  exists with different identity fields, returns an error. If it doesn't exist, creates it.
  The CID comes from getRecord or putRecord; a missing CID is returned as nil.
  """
  @spec ensure_exists(Client.t(), String.t(), DateTime.t()) :: result()
  def ensure_exists(client \\ ContextBot.ATProto.ReqClient, repo, created_at)
      when is_binary(repo) and is_struct(created_at, DateTime) do
    record = build_record(created_at)
    uri = "at://#{repo}/#{@collection}/#{@publication_rkey}"

    case client.get_record(repo, @collection, @publication_rkey) do
      {:ok, _status, _headers, body} ->
        accept_existing(body, record, uri)

      {:error, :record_not_found} ->
        create_record(client, repo, record, uri)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the stable publication URI for the given repository.
  """
  @spec publication_uri(String.t()) :: String.t()
  def publication_uri(repo) when is_binary(repo) do
    "at://#{repo}/#{@collection}/#{@publication_rkey}"
  end

  defp accept_existing(%{"value" => existing} = body, record, uri) when is_map(existing) do
    if publication_matches?(existing, record) do
      {:ok, %{uri: uri, cid: Client.recorded_cid(body)}}
    else
      {:error, :publication_conflict}
    end
  end

  defp accept_existing(_body, _record, _uri), do: {:error, :publication_conflict}

  defp create_record(client, repo, record, uri) do
    case client.put_record(repo, @collection, @publication_rkey, record) do
      {:ok, _status, _headers, body} ->
        cid = Client.recorded_cid(body) || fetch_recorded_cid(client, repo)
        {:ok, %{uri: uri, cid: cid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_recorded_cid(client, repo) do
    case client.get_record(repo, @collection, @publication_rkey) do
      {:ok, _status, _headers, body} -> Client.recorded_cid(body)
      _missing -> nil
    end
  end

  defp publication_matches?(existing, desired) do
    Map.get(existing, "$type") == desired["$type"] and
      Map.get(existing, "url") == desired["url"] and
      Map.get(existing, "name") == desired["name"]
  end

  defp build_record(created_at) do
    %{
      "$type" => @collection,
      "url" => @publication_url,
      "name" => @publication_name,
      "createdAt" => DateTime.to_iso8601(created_at)
    }
  end
end
