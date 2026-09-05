defmodule ContextBot.StandardSite.PromptDocument do
  @moduledoc """
  Publishes versioned prompt templates as stable Standard.site documents.

  Each rkey is content-addressed from the current prompt bytes so identical
  prompts reuse one public artifact. A hash mismatch on that rkey is a
  conflict, not a silent overwrite. Existing records are never rewritten.
  """

  alias ContextBot.ATProto.Client
  alias ContextBot.Research.Request
  alias ContextBot.StandardSite.Document

  @collection "site.standard.document"

  @type result ::
          {:ok, %{uri: String.t(), rkey: String.t(), reader_url: String.t()}}
          | {:error, atom() | Client.error_reason()}

  @doc """
  Ensures the current research system-prompt document exists and returns its reader location.
  """
  @spec ensure_exists(Client.t(), String.t(), String.t(), DateTime.t()) :: result()
  def ensure_exists(client \\ ContextBot.ATProto.ReqClient, repo, publication_uri, created_at)
      when is_binary(repo) and is_binary(publication_uri) and is_struct(created_at, DateTime) do
    ensure_prompt(client, repo, publication_uri, created_at, research_spec())
  end

  @doc """
  Ensures the current structure-prompt document exists and returns its reader location.
  """
  @spec ensure_structure_exists(Client.t(), String.t(), String.t(), DateTime.t()) :: result()
  def ensure_structure_exists(
        client \\ ContextBot.ATProto.ReqClient,
        repo,
        publication_uri,
        created_at
      )
      when is_binary(repo) and is_binary(publication_uri) and is_struct(created_at, DateTime) do
    ensure_prompt(client, repo, publication_uri, created_at, structure_spec())
  end

  defp ensure_prompt(client, repo, publication_uri, created_at, spec) do
    rkey = spec.rkey
    uri = "at://#{repo}/#{@collection}/#{rkey}"

    case client.get_record(repo, @collection, rkey) do
      {:ok, _status, _headers, %{"value" => existing}} when is_map(existing) ->
        accept_existing(existing, uri, rkey, spec)

      {:error, :record_not_found} ->
        create_record(client, repo, publication_uri, created_at, uri, rkey, spec)

      {:error, reason} ->
        {:error, reason}

      {:ok, _status, _headers, _body} ->
        {:error, :prompt_document_conflict}
    end
  end

  defp accept_existing(existing, uri, rkey, spec) do
    if prompt_matches?(existing, spec) do
      {:ok, location(uri, rkey)}
    else
      {:error, :prompt_document_conflict}
    end
  end

  defp create_record(client, repo, publication_uri, created_at, uri, rkey, spec) do
    case client.put_record(
           repo,
           @collection,
           rkey,
           build_record(publication_uri, created_at, spec)
         ) do
      {:ok, _status, _headers, _body} -> {:ok, location(uri, rkey)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp location(uri, rkey) do
    %{uri: uri, rkey: rkey, reader_url: Document.reader_url_from_uri(uri)}
  end

  defp prompt_matches?(existing, spec) do
    Map.get(existing, "$type") == @collection and Map.get(existing, "textContent") == spec.text
  end

  defp research_spec do
    %{
      id: Request.system_prompt_id(),
      version: Request.system_prompt_semantic_version(),
      sha256: Request.system_prompt_sha256(),
      rkey: Request.system_prompt_rkey(),
      text: Request.system_prompt(),
      title: "Context Bot system prompt #{Request.system_prompt_id()}",
      heading: "Context Bot system prompt",
      role:
        "This is the versioned system prompt Context Bot sends as the Anthropic Messages `system` field."
    }
  end

  defp structure_spec do
    %{
      id: Request.structure_prompt_id(),
      version: Request.structure_prompt_semantic_version(),
      sha256: Request.structure_prompt_sha256(),
      rkey: Request.structure_prompt_rkey(),
      text: Request.structure_prompt(),
      title: "Context Bot structure prompt #{Request.structure_prompt_id()}",
      heading: "Context Bot structure prompt",
      role:
        "This is the versioned system prompt Context Bot sends as the Anthropic Messages `system` field for the structure call."
    }
  end

  defp build_record(publication_uri, created_at, spec) do
    %{
      "$type" => @collection,
      "site" => publication_uri,
      "title" => spec.title,
      "description" => "Version #{spec.version} (SHA-256 #{spec.sha256}).",
      "textContent" => spec.text,
      "content" => %{
        "$type" => "at.markpub.markdown",
        "text" => %{
          "$type" => "at.markpub.text",
          "markdown" => format_markdown(spec)
        }
      },
      "publishedAt" => DateTime.to_iso8601(created_at)
    }
  end

  defp format_markdown(spec) do
    """
    # #{spec.heading}

    - id: `#{spec.id}`
    - semantic version: `#{spec.version}`
    - SHA-256: `#{spec.sha256}`

    #{spec.role}
    Hidden model reasoning is not available. The same prompt and parameters do not guarantee an
    identical Claude response.

    ## System prompt

    ```
    #{String.trim_trailing(spec.text)}
    ```
    """
  end
end
