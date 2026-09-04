defmodule ContextBot.StandardSite.ReaderIndex do
  @moduledoc """
  Asks Standard Reader's public AppView whether a `site.standard.document` is indexed.

  Detection uses `app.standard-reader.getDocument`, not the `/a/{did}/{rkey}` HTML
  shell. The HTML page returns 200 with `<title>Article</title>` before Tap
  indexes the record; scraping that shell is brittle. The XRPC read-model is
  the same index the Reader UI eventually renders.

  Observed on the wire (2026-09-04):

  * indexed: HTTP 200 JSON with matching `uri` and `hasRenderableBody: true`
    (and usually `content` + a real `title`)
  * not indexed: HTTP 400 `InvalidRequest` / `Document not found`
  * anything else (timeout, 5xx, malformed JSON, 200 without a renderable
    body): `:ambiguous` — callers stay on the getcontext.bot mirror
  """

  alias ContextBot.HTTP.BodyLimit
  alias ContextBot.Settings

  @appview_url "https://standard-reader.app"
  @get_document_nsid "app.standard-reader.getDocument"
  @max_response_bytes 1_000_000
  @receive_timeout_ms 5_000
  @generic_title "Article"

  @type check_result :: :indexed | :not_indexed | :ambiguous

  @doc "Probes Standard Reader for one document AT URI."
  @spec check(String.t()) :: check_result()
  def check(document_uri) when is_binary(document_uri) and document_uri != "" do
    case request_document(document_uri) do
      {:ok, status, body} -> classify(status, body, document_uri)
      {:error, _reason} -> :ambiguous
    end
  end

  def check(_document_uri), do: :ambiguous

  @doc """
  Classifies one AppView response. Public so tests can cover the contract
  without opening sockets.
  """
  @spec classify(integer(), term(), String.t()) :: check_result()
  def classify(status, body, expected_uri)
      when is_integer(status) and is_binary(expected_uri) do
    cond do
      status in 200..299 and indexed_document?(body, expected_uri) ->
        :indexed

      not_found?(status, body) ->
        :not_indexed

      true ->
        :ambiguous
    end
  end

  def classify(_status, _body, _expected_uri), do: :ambiguous

  defp indexed_document?(body, expected_uri) when is_map(body) do
    uri_match?(body, expected_uri) and renderable?(body)
  end

  defp indexed_document?(_body, _expected_uri), do: false

  defp uri_match?(%{"uri" => uri}, expected_uri) when is_binary(uri),
    do: uri == expected_uri

  defp uri_match?(_body, _expected_uri), do: false

  defp renderable?(%{"hasRenderableBody" => true} = body) do
    present_title?(body) or markdown_present?(body["content"])
  end

  defp renderable?(%{"content" => content} = body) do
    present_title?(body) and markdown_present?(content)
  end

  defp renderable?(_body), do: false

  defp present_title?(%{"title" => title}) when is_binary(title) do
    trimmed = String.trim(title)
    trimmed != "" and trimmed != @generic_title
  end

  defp present_title?(_body), do: false

  defp markdown_present?(%{"text" => %{"markdown" => markdown}})
       when is_binary(markdown) and markdown != "",
       do: true

  defp markdown_present?(%{"text" => text}) when is_binary(text) and text != "", do: true
  defp markdown_present?(_content), do: false

  defp not_found?(status, body) when status in 400..404 do
    error = body_error(body)
    message = body_message(body)

    error in ["NotFound", "RecordNotFound"] or
      (error == "InvalidRequest" and String.contains?(message, "not found")) or
      (status == 404 and error in ["InvalidRequest", "NotFound", "RecordNotFound", ""])
  end

  defp not_found?(_status, _body), do: false

  defp body_error(%{"error" => error}) when is_binary(error), do: error
  defp body_error(_body), do: ""

  defp body_message(%{"message" => message}) when is_binary(message) do
    String.downcase(message)
  end

  defp body_message(_body), do: ""

  defp request_document(document_uri) do
    settings = Application.fetch_env!(:context_bot, :settings)
    timeout = receive_timeout(settings)

    common_options = [
      finch: [
        name: ContextBot.Finch,
        pool_timeout: 5_000,
        receive_timeout: timeout,
        request_timeout: timeout + 5_000
      ],
      raw: true,
      retry: false
    ]

    options = Keyword.merge(config()[:req_options] || [], common_options)

    Req.new(options)
    |> BodyLimit.attach(@max_response_bytes)
    |> Req.request(
      method: :get,
      url: @appview_url <> "/xrpc/" <> @get_document_nsid,
      params: [document: document_uri]
    )
    |> decode_json_response()
    |> normalize_response()
  end

  defp receive_timeout(%Settings{atproto_http_timeout_ms: timeout})
       when is_integer(timeout) and timeout > 0 do
    min(timeout, @receive_timeout_ms)
  end

  defp receive_timeout(_settings), do: @receive_timeout_ms

  defp decode_json_response({:ok, %Req.Response{status: status}} = result)
       when status in 500..599,
       do: result

  defp decode_json_response(
         {:ok, %Req.Response{headers: headers, body: body} = response} = result
       )
       when is_binary(body) do
    if json_response?(headers) do
      case Jason.decode(body) do
        {:ok, decoded_body} -> {:ok, %{response | body: decoded_body}}
        {:error, error} -> {:error, error}
      end
    else
      result
    end
  end

  defp decode_json_response(result), do: result

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:ok, status, body}

  defp normalize_response({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout}

  defp normalize_response({:error, %{reason: :timeout}}), do: {:error, :timeout}

  defp normalize_response({:error, %BodyLimit.ResponseTooLargeError{}}),
    do: {:error, :response_too_large}

  defp normalize_response({:error, _exception}), do: {:error, :transport}

  defp json_response?(headers) do
    Enum.any?(Map.get(headers, "content-type", []), fn content_type ->
      media_type = content_type |> String.split(";", parts: 2) |> hd() |> String.trim()
      media_type == "application/json" or String.ends_with?(media_type, "+json")
    end)
  end

  defp config, do: Application.get_env(:context_bot, __MODULE__, [])
end
