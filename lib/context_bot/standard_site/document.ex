defmodule ContextBot.StandardSite.Document do
  @moduledoc """
  Builds and publishes Standard.site document records containing full research responses.

  New documents use a short topic summary as Reader `title`, the invoking-post
  text as written as `description`, and open the Markpub body with an Asked block
  plus a Claude continue link. Existing published records are not rewritten.
  """

  alias ContextBot.ATProto.{Client, TID}
  alias ContextBot.StandardSite.PageCopy

  @collection "site.standard.document"
  @reader_base_url "https://standard-reader.app/a"
  @claude_new_url "https://claude.ai/new"
  @continue_link_text "Continue this conversation in Claude"
  @parameter_order [
    "anthropic-version",
    "model",
    "max_tokens",
    "effort",
    "thinking",
    "tool_choice",
    "cache_control",
    "stream",
    "continuation",
    "length_repair",
    "research_max_tokens",
    "length_repair_max_tokens"
  ]

  @type document_content :: %{
          required(:full_response) => String.t(),
          required(:selected_reply) => String.t(),
          required(:invocation_uri) => String.t(),
          required(:prompt) => %{
            required(:id) => String.t(),
            required(:semantic_version) => String.t(),
            required(:sha256) => String.t(),
            required(:reader_url) => String.t()
          },
          required(:parameters) => %{optional(String.t()) => term()},
          required(:user_message) => %{required(String.t()) => term()},
          optional(:asked_text) => String.t(),
          optional(:parent_uri) => String.t() | nil,
          optional(:document_title) => String.t() | nil,
          optional(:document_reader_url) => String.t()
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
    with :ok <- validate_public_inputs(content) do
      rkey = TID.generate(DateTime.to_unix(created_at, :microsecond))
      document_url = reader_url(repo, rkey)

      record =
        build_record(
          publication_uri,
          Map.put(content, :document_reader_url, document_url),
          created_at
        )

      case client.put_record(repo, @collection, rkey, record) do
        {:ok, _status, _headers, _body} ->
          uri = "at://#{repo}/#{@collection}/#{rkey}"
          {:ok, %{uri: uri, rkey: rkey, reader_url: document_url}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Public Standard Reader URL for a stored `site.standard.document` AT URI.

  Returns nil when the URI is missing or is not that collection. The scheme matches
  the compact-reply facet: `https://standard-reader.app/a/{did}/{rkey}`.
  """
  @spec reader_url_from_uri(String.t() | nil) :: String.t() | nil
  def reader_url_from_uri("at://" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [did, @collection, rkey] when did != "" and rkey != "" ->
        reader_url(did, rkey)

      _ ->
        nil
    end
  end

  def reader_url_from_uri(_uri), do: nil

  defp reader_url(did, rkey), do: "#{@reader_base_url}/#{did}/#{rkey}"

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
      "title" => PageCopy.title(content),
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
    |> maybe_put_description(PageCopy.description(content))
  end

  defp maybe_put_description(record, nil), do: record
  defp maybe_put_description(record, description), do: Map.put(record, "description", description)

  @doc """
  Markdown published on the Standard Reader full-response page.

  Requires a prompt-document reader URL, prompt identity/hash, the allowlisted
  Messages API parameters, and the canonical user message. Missing prompt inputs
  are a create error; they are never omitted from a published full response.

  New documents also include a `claude.ai/new?q=` continue link whose starter
  prompt names this document's Standard Reader URL. The writeup and system
  prompt are not copied into the query string.
  """
  @spec format_markdown(document_content()) :: String.t()
  def format_markdown(
        %{
          full_response: full_response,
          selected_reply: selected_reply,
          prompt: prompt,
          parameters: parameters,
          user_message: user_message
        } = content
      )
      when is_binary(full_response) and is_binary(selected_reply) do
    :ok = validate_public_inputs(content)

    """
    #{PageCopy.asked_markdown(content)}

    #{continue_markdown(content)}

    # Research Analysis

    #{full_response}

    ---

    ## Summary

    #{selected_reply}

    ---

    ## How this response was produced

    Prompt template: [#{prompt.id}](#{prompt.reader_url})
    Semantic version: `#{prompt.semantic_version}`
    SHA-256: `#{prompt.sha256}`

    Hidden model reasoning is not available and is not part of this page. The same
    prompt and parameters do not guarantee an identical Claude response.

    ### Messages API parameters

    #{format_parameters(parameters)}

    #{format_tools(parameters)}
    ### Canonical thread

    The first user message sent to the Messages API:

    ```
    #{user_message_text(user_message)}
    ```
    #{format_images(user_message)}
    """
  end

  defp continue_markdown(content) do
    case document_reader_url(content) do
      url when is_binary(url) ->
        "[#{@continue_link_text}](#{claude_continue_href(url)})"

      _missing ->
        ""
    end
  end

  defp claude_continue_href(reader_url) do
    "#{@claude_new_url}?q=#{URI.encode_www_form(continue_starter_prompt(reader_url))}"
  end

  defp continue_starter_prompt(reader_url) do
    """
    Please fetch and use this public Context Bot research page as prior context: #{reader_url}

    Then wait for my follow-up. Do not summarize unless I ask.
    """
    |> String.trim()
  end

  defp document_reader_url(content) when is_map(content) do
    case Map.get(content, :document_reader_url) || Map.get(content, "document_reader_url") do
      url when is_binary(url) and url != "" ->
        if String.starts_with?(url, "#{@reader_base_url}/"), do: url, else: nil

      _missing ->
        nil
    end
  end

  defp validate_public_inputs(%{
         prompt: prompt,
         parameters: parameters,
         user_message: user_message
       })
       when is_map(prompt) and is_map(parameters) and is_map(user_message) do
    with :ok <- validate_prompt(prompt) do
      validate_user_message(user_message)
    end
  end

  defp validate_public_inputs(_content), do: {:error, :prompt_inputs_missing}

  defp validate_prompt(%{id: id, semantic_version: version, sha256: sha256, reader_url: url})
       when is_binary(id) and id != "" and is_binary(version) and version != "" and
              is_binary(sha256) and sha256 != "" and is_binary(url) and
              byte_size(url) > 0 do
    if String.starts_with?(url, "#{@reader_base_url}/") do
      :ok
    else
      {:error, :prompt_inputs_missing}
    end
  end

  defp validate_prompt(_prompt), do: {:error, :prompt_inputs_missing}

  defp validate_user_message(user_message) do
    case user_message_text(user_message) do
      text when text != "" -> :ok
      _empty -> {:error, :prompt_inputs_missing}
    end
  end

  defp user_message_text(%{"text" => text}) when is_binary(text), do: text
  defp user_message_text(%{text: text}) when is_binary(text), do: text
  defp user_message_text(_user_message), do: ""

  defp format_parameters(parameters) do
    @parameter_order
    |> Enum.filter(&Map.has_key?(parameters, &1))
    |> Enum.map_join("\n", fn key ->
      "- `#{key}`: #{format_parameter_value(parameters[key])}"
    end)
  end

  defp format_parameter_value(value) when is_binary(value), do: value

  defp format_parameter_value(value) when is_boolean(value) or is_integer(value),
    do: to_string(value)

  defp format_parameter_value(value), do: inspect(value)

  defp format_tools(%{"tools" => tools}) when is_list(tools) and tools != [] do
    rows =
      Enum.map_join(tools, "\n", fn tool ->
        name = tool["name"] || tool["type"] || "tool"
        details = tool_detail_parts(tool)
        "- `#{name}` (#{tool["type"]}): #{Enum.join(details, ", ")}"
      end)

    """
    ### Tools

    #{rows}

    """
  end

  defp format_tools(_parameters), do: ""

  defp tool_detail_parts(tool) do
    []
    |> maybe_tool_part("allowed_callers", tool["allowed_callers"])
    |> maybe_tool_part("max_uses", tool["max_uses"])
    |> maybe_tool_part("max_content_tokens", tool["max_content_tokens"])
    |> maybe_tool_part("response_inclusion", tool["response_inclusion"])
  end

  defp maybe_tool_part(parts, _key, nil), do: parts

  defp maybe_tool_part(parts, key, value),
    do: parts ++ ["#{key}=#{format_parameter_value(value)}"]

  defp format_images(user_message) do
    images = user_message["images"] || user_message[:images] || []

    urls =
      Enum.flat_map(List.wrap(images), fn
        %{"url" => url} when is_binary(url) and url != "" -> [url]
        %{url: url} when is_binary(url) and url != "" -> [url]
        _other -> []
      end)

    case urls do
      [] ->
        ""

      urls ->
        list = Enum.map_join(urls, "\n", fn url -> "- #{url}" end)

        """

        Images included in that message:

        #{list}
        """
    end
  end
end
