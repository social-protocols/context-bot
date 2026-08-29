defmodule ContextBot.Research.AnthropicClient do
  @moduledoc """
  Req-backed Anthropic Messages client that returns bounded raw response bytes.
  """

  @behaviour ContextBot.Research.Client

  alias ContextBot.Funding
  alias ContextBot.HTTP.BodyLimit

  @base_url "https://api.anthropic.com"
  @pool_checkout_error_prefix "Finch was unable to provide a connection within the timeout due to excess queuing for connections."
  @safe_response_headers ["content-type", "request-id", "retry-after"]
  @max_retained_header_bytes 16_384

  @impl true
  def send_message(request_map, attempt_metadata)
      when is_map(request_map) and is_map(attempt_metadata) do
    started_at = System.monotonic_time(:millisecond)
    settings = Application.fetch_env!(:context_bot, :settings)

    request_map =
      request_map
      |> Map.delete(:stream)
      |> Map.put("stream", false)

    result =
      request(attempt_metadata, settings)
      |> BodyLimit.attach(settings.max_response_bytes)
      |> execute_request(request_map)

    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
    normalize_response(result, duration_ms)
  end

  defp request(attempt_metadata, settings) do
    config = config()
    timeout = config[:timeout] || settings.anthropic_http_timeout_ms
    api_key = Funding.credential(fund_id(attempt_metadata))

    common_options = [
      base_url: config[:base_url] || @base_url,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", settings.anthropic_api_version}
      ],
      finch: [
        name: ContextBot.Finch,
        pool_timeout: 5_000,
        receive_timeout: timeout,
        request_timeout: timeout + 5_000
      ],
      finch_private: %{context_bot_attempt: attempt_metadata},
      raw: true,
      redirect: false,
      retry: false
    ]

    options = Keyword.merge(config[:req_options] || [], common_options)
    Req.new(options)
  end

  defp execute_request(request, request_map) do
    Req.post(request, url: "/v1/messages", json: request_map)
  rescue
    error in RuntimeError ->
      if String.starts_with?(error.message, @pool_checkout_error_prefix) do
        {:error, :pool_checkout_exhausted}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp normalize_response(
         {:ok, %Req.Response{status: status, headers: headers, body: raw_body}},
         duration_ms
       )
       when is_integer(status) and status > 0 and is_binary(raw_body) do
    {headers, headers_truncated?} = safe_headers(headers)

    {:ok,
     maybe_mark_headers_truncated(
       %{
         status: status,
         headers: headers,
         raw_body: raw_body,
         received_at: DateTime.utc_now(),
         duration_ms: duration_ms
       },
       headers_truncated?
     )}
  end

  defp normalize_response({:error, %BodyLimit.ResponseTooLargeError{}}, _duration_ms),
    do: {:error, :response_too_large}

  defp normalize_response({:error, %Req.TransportError{reason: :timeout}}, _duration_ms),
    do: {:error, :timeout}

  defp normalize_response({:error, %{reason: :timeout}}, _duration_ms),
    do: {:error, :timeout}

  defp normalize_response({:error, :pool_checkout_exhausted}, _duration_ms),
    do: {:error, :transport}

  defp normalize_response({:error, _exception}, _duration_ms), do: {:error, :transport}

  defp safe_headers(headers) do
    headers
    |> Map.new(fn {name, values} -> {name, List.wrap(values)} end)
    |> Enum.filter(fn {name, _values} -> safe_response_header?(name) end)
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Enum.reduce({%{}, false}, fn {name, values}, {retained, truncated?} ->
      candidate = Map.put(retained, name, values)

      if encoded_size(candidate) <= @max_retained_header_bytes do
        {candidate, truncated?}
      else
        {retained, true}
      end
    end)
  end

  defp safe_response_header?(name),
    do: name in @safe_response_headers or String.starts_with?(name, "anthropic-ratelimit-")

  defp encoded_size(value), do: value |> :erlang.term_to_binary([:deterministic]) |> byte_size()

  defp maybe_mark_headers_truncated(envelope, true),
    do: Map.put(envelope, :headers_truncated, true)

  defp maybe_mark_headers_truncated(envelope, false), do: envelope

  defp fund_id(metadata) when is_map(metadata) do
    metadata[:fund_id] || metadata["fund_id"]
  end

  defp fund_id(_metadata), do: nil

  defp config, do: Application.get_env(:context_bot, __MODULE__, [])
end
