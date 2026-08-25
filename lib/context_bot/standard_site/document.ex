defmodule ContextBot.StandardSite.Document do
  @moduledoc """
  Builds and publishes Standard.site document records containing full research responses.

  Each document includes the full research writeup in both plain text and Markpub format
  for inline reading, along with metadata linking to the publication and Bluesky post.
  """

  alias ContextBot.ATProto.Client

  @collection "site.standard.document"
  @reader_base_url "https://standard-reader.app/a"

  @type document_content :: %{
          required(:full_response) => String.t(),
          required(:selected_reply) => String.t(),
          required(:invocation_uri) => String.t()
        }

  @type result ::
          {:ok, %{uri: String.t(), rkey: String.t(), reader_url: String.t()}}
          | {:error, atom()}

  @doc """
  Creates a Standard.site document record for the full research response.

  Returns the document URI, rkey, and reader URL on success.
  """
  @spec create(Client.t(), String.t(), String.t(), document_content(), DateTime.t()) :: result()
  def create(
        client \\ ContextBot.ATProto.ReqClient,
        repo,
        publication_uri,
        content,
        created_at
      )
      when is_binary(repo) and is_binary(publication_uri) and
             is_map(content) and is_struct(created_at, DateTime) do
    rkey = TID.generate(DateTime.to_unix(created_at, :microsecond))
    record = build_record(publication_uri, content, created_at)

    case client.put_record(repo, @collection, rkey, record) do
      {:ok, _status, _headers, _body} ->
        uri = "at://#{repo}/#{@collection}/#{rkey}"
        reader_url = "#{@reader_base_url}/#{repo}/#{rkey}"
        {:ok, %{uri: uri, rkey: rkey, reader_url: reader_url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates an existing document to add the bskyPostRef after the Bluesky reply is published.

  This is a best-effort operation. Failures are logged but do not block the workflow.
  """
  @spec add_post_ref(Client.t(), String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def add_post_ref(
        client \\ ContextBot.ATProto.ReqClient,
        repo,
        rkey,
        post_uri
      )
      when is_binary(repo) and is_binary(rkey) and is_binary(post_uri) do
    case client.get_record(repo, @collection, rkey) do
      {:ok, _status, _headers, %{"value" => record}} when is_map(record) ->
        updated_record = Map.put(record, "bskyPostRef", post_uri)

        case client.put_record(repo, @collection, rkey, updated_record) do
          {:ok, _status, _headers, _body} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_record(publication_uri, content, created_at) do
    %{
      "$type" => @collection,
      "site" => publication_uri,
      "title" => title_from_invocation(content.invocation_uri),
      "description" => String.slice(content.selected_reply, 0..150),
      "textContent" => content.full_response,
      "content" => %{
        "$type" => "at.markpub.markdown",
        "text" => %{
          "$type" => "at.markpub.text",
          "markdown" => format_markdown(content)
        }
      },
      "publishedAt" => DateTime.to_iso8601(created_at)
    }
  end

  defp title_from_invocation(invocation_uri) do
    # Extract a short title from the invocation URI
    # e.g., "at://did:plc:abc123.../app.bsky.feed.post/3k..." -> "Context on 3k..."
    case String.split(invocation_uri, "/") do
      [_, _, _, _, rkey] -> "Context on #{String.slice(rkey, 0..7)}..."
      _ -> "Context Research"
    end
  end

  defp format_markdown(%{full_response: full_response, selected_reply: selected_reply}) do
    """
    # Research Analysis

    #{full_response}

    ---

    ## Summary

    #{selected_reply}
    """
  end
end
