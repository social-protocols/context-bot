defmodule ContextBot.StandardSite.PromptDocument do
  @moduledoc """
  Publishes the versioned system prompt as a stable Standard.site document.

  The rkey is content-addressed from the current `CONTEXT_BOT_SYSTEM_*` bytes so
  identical prompts reuse one public artifact. A hash mismatch on that rkey is a
  conflict, not a silent overwrite.
  """

  alias ContextBot.ATProto.Client
  alias ContextBot.Research.Request
  alias ContextBot.StandardSite.Document

  @collection "site.standard.document"

  @type result ::
          {:ok, %{uri: String.t(), rkey: String.t(), reader_url: String.t()}}
          | {:error, atom() | Client.error_reason()}

  @doc """
  Ensures the current system-prompt document exists and returns its reader location.
  """
  @spec ensure_exists(Client.t(), String.t(), String.t(), DateTime.t()) :: result()
  def ensure_exists(client \\ ContextBot.ATProto.ReqClient, repo, publication_uri, created_at)
      when is_binary(repo) and is_binary(publication_uri) and is_struct(created_at, DateTime) do
    rkey = Request.system_prompt_rkey()
    uri = "at://#{repo}/#{@collection}/#{rkey}"

    case client.get_record(repo, @collection, rkey) do
      {:ok, _status, _headers, %{"value" => existing}} when is_map(existing) ->
        accept_existing(existing, uri, rkey)

      {:error, :record_not_found} ->
        create_record(client, repo, publication_uri, created_at, uri, rkey)

      {:error, reason} ->
        {:error, reason}

      {:ok, _status, _headers, _body} ->
        {:error, :prompt_document_conflict}
    end
  end

  defp accept_existing(existing, uri, rkey) do
    if prompt_matches?(existing) do
      {:ok, location(uri, rkey)}
    else
      {:error, :prompt_document_conflict}
    end
  end

  defp create_record(client, repo, publication_uri, created_at, uri, rkey) do
    case client.put_record(repo, @collection, rkey, build_record(publication_uri, created_at)) do
      {:ok, _status, _headers, _body} -> {:ok, location(uri, rkey)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp location(uri, rkey) do
    %{uri: uri, rkey: rkey, reader_url: Document.reader_url_from_uri(uri)}
  end

  defp prompt_matches?(existing) do
    Map.get(existing, "$type") == @collection and
      Map.get(existing, "textContent") == Request.system_prompt()
  end

  defp build_record(publication_uri, created_at) do
    prompt = Request.system_prompt()

    %{
      "$type" => @collection,
      "site" => publication_uri,
      "title" => "Context Bot system prompt #{Request.system_prompt_id()}",
      "description" =>
        "Version #{Request.system_prompt_semantic_version()} (SHA-256 #{Request.system_prompt_sha256()}).",
      "textContent" => prompt,
      "content" => %{
        "$type" => "at.markpub.markdown",
        "text" => %{
          "$type" => "at.markpub.text",
          "markdown" => format_markdown()
        }
      },
      "publishedAt" => DateTime.to_iso8601(created_at)
    }
  end

  defp format_markdown do
    """
    # Context Bot system prompt

    - id: `#{Request.system_prompt_id()}`
    - semantic version: `#{Request.system_prompt_semantic_version()}`
    - SHA-256: `#{Request.system_prompt_sha256()}`

    This is the versioned system prompt Context Bot sends as the Anthropic Messages `system` field.
    Hidden model reasoning is not available. The same prompt and parameters do not guarantee an
    identical Claude response.

    ## System prompt

    ```
    #{String.trim_trailing(Request.system_prompt())}
    ```

    ## Length-repair prompt

    Appended as a user turn only when the compact Bluesky reply exceeds the post limit.

    - id: `LENGTH_REPAIR`
    - SHA-256: `#{Request.length_repair_sha256()}`

    ```
    #{String.trim_trailing(Request.length_repair_prompt())}
    ```
    """
  end
end
