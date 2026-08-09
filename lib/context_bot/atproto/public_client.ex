defmodule ContextBot.ATProto.PublicClient do
  @moduledoc """
  Read-only, unauthenticated access to the public Bluesky AppView endpoints used by dry runs.
  """

  alias ContextBot.HTTP.BodyLimit

  @spec resolve_handle(String.t()) :: ContextBot.ATProto.Client.result()
  def resolve_handle(handle) when is_binary(handle) do
    request(
      method: :get,
      url: appview_url() <> "/xrpc/com.atproto.identity.resolveHandle",
      params: [handle: handle]
    )
  end

  @spec get_post_thread(String.t(), pos_integer()) :: ContextBot.ATProto.Client.result()
  def get_post_thread(uri, parent_height)
      when is_binary(uri) and is_integer(parent_height) and parent_height > 0 do
    request(
      method: :get,
      url: appview_url() <> "/xrpc/app.bsky.feed.getPostThread",
      params: [uri: uri, depth: 0, parentHeight: parent_height]
    )
  end

  defp request(request_options) do
    settings = Application.fetch_env!(:context_bot, :settings)
    timeout = config()[:timeout] || settings.atproto_http_timeout_ms

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
    |> BodyLimit.attach(settings.max_response_bytes)
    |> Req.request(request_options)
    |> decode_json_response()
    |> normalize_response()
  end

  defp decode_json_response({:ok, %Req.Response{status: status}} = result)
       when status in [401, 429] or status in 500..599,
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

  defp normalize_response({:ok, %Req.Response{status: status, headers: headers, body: body}})
       when status in 200..299,
       do: {:ok, status, headers, body}

  defp normalize_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}

  defp normalize_response({:ok, %Req.Response{status: 429, headers: headers}}),
    do: {:error, {:rate_limited, first_header(headers, "retry-after")}}

  defp normalize_response({:ok, %Req.Response{status: status}}) when status in 500..599,
    do: {:error, {:transient, status}}

  defp normalize_response({:ok, %Req.Response{body: %{"error" => "RecordNotFound"}}}),
    do: {:error, :record_not_found}

  defp normalize_response({:ok, %Req.Response{status: status}}),
    do: {:error, {:permanent, status}}

  defp normalize_response({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout}

  defp normalize_response({:error, %{reason: :timeout}}), do: {:error, :timeout}

  defp normalize_response({:error, %BodyLimit.ResponseTooLargeError{}}),
    do: {:error, :response_too_large}

  defp normalize_response({:error, _exception}), do: {:error, {:transient, :transport}}

  defp first_header(headers, name) do
    case Map.get(headers, name, []) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp json_response?(headers) do
    Enum.any?(Map.get(headers, "content-type", []), fn content_type ->
      media_type = content_type |> String.split(";", parts: 2) |> hd() |> String.trim()
      media_type == "application/json" or String.ends_with?(media_type, "+json")
    end)
  end

  defp appview_url do
    settings = Application.fetch_env!(:context_bot, :settings)
    url = config()[:appview_url] || settings.appview_url
    String.trim_trailing(url, "/")
  end

  defp config, do: Application.get_env(:context_bot, __MODULE__, [])
end
