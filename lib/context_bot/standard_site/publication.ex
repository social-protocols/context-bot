defmodule ContextBot.StandardSite.Publication do
  @moduledoc """
  Ensures the bot's Standard.site publication record exists.

  A publication is a one-time record that describes the publication source.
  It uses a stable rkey and persists for the lifetime of the bot.
  """

  alias ContextBot.ATProto.{Client, TID}

  @collection "site.standard.publication"
  @publication_rkey "context-bot"
  @publication_url "https://getcontext.bot"
  @publication_name "Context Bot"

  @type result :: {:ok, String.t()} | {:error, atom()}

  @doc """
  Ensures the publication record exists and returns its AT URI.

  This operation is idempotent. If the record already exists with matching content,
  returns success. If it exists with different content, returns an error.
  If it doesn't exist, creates it.
  """
  @spec ensure_exists(Client.t(), String.t(), DateTime.t()) :: result()
  def ensure_exists(client \\ ContextBot.ATProto.ReqClient, repo, created_at)
      when is_binary(repo) and is_struct(created_at, DateTime) do
    record = build_record(created_at)
    uri = "at://#{repo}/#{@collection}/#{@publication_rkey}"

    case client.get_record(repo, @collection, @publication_rkey) do
      {:ok, _status, _headers, %{"value" => ^record}} ->
        {:ok, uri}

      {:error, :record_not_found} ->
        case client.put_record(repo, @collection, @publication_rkey, record) do
          {:ok, _status, _headers, _body} -> {:ok, uri}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      {:ok, _status, _headers, _body} ->
        {:error, :publication_conflict}
    end
  end

  @doc """
  Returns the stable publication URI for the given repository.
  """
  @spec publication_uri(String.t()) :: String.t()
  def publication_uri(repo) when is_binary(repo) do
    "at://#{repo}/#{@collection}/#{@publication_rkey}"
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
