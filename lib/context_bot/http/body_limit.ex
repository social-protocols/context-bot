defmodule ContextBot.HTTP.BodyLimit do
  @moduledoc """
  Streams a Req response into memory while enforcing an exact byte limit.
  """

  @state_key :context_bot_body_limit

  defmodule ResponseTooLargeError do
    @moduledoc false

    defexception [:limit, message: "response exceeded configured byte limit"]
  end

  @spec attach(Req.Request.t(), pos_integer()) :: Req.Request.t()
  def attach(%Req.Request{} = request, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    into = fn {:data, chunk}, {request, response} ->
      collect_chunk(request, response, chunk, max_bytes)
    end

    request
    |> Map.replace!(:into, into)
    |> Req.Request.prepend_response_steps(enforce_body_limit: &finalize_response(&1, max_bytes))
  end

  defp collect_chunk(request, response, chunk, max_bytes) do
    state = Req.Response.get_private(response, @state_key, %{size: 0, chunks: []})
    size = state.size + byte_size(chunk)

    if content_length_exceeds?(response, max_bytes) or size > max_bytes do
      response = Req.Response.put_private(response, @state_key, :too_large)
      {:halt, {request, response}}
    else
      state = %{size: size, chunks: [chunk | state.chunks]}
      response = Req.Response.put_private(response, @state_key, state)
      {:cont, {request, response}}
    end
  end

  defp finalize_response({request, response}, max_bytes) do
    case Req.Response.get_private(response, @state_key) do
      :too_large ->
        {request, ResponseTooLargeError.exception(limit: max_bytes)}

      state when is_map(state) ->
        if content_length_exceeds?(response, max_bytes) do
          {request, ResponseTooLargeError.exception(limit: max_bytes)}
        else
          body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
          response = %{response | body: body, private: Map.delete(response.private, @state_key)}
          {request, response}
        end

      nil ->
        if content_length_exceeds?(response, max_bytes) do
          {request, ResponseTooLargeError.exception(limit: max_bytes)}
        else
          {request, response}
        end
    end
  end

  defp content_length_exceeds?(response, max_bytes) do
    Enum.any?(Req.Response.get_header(response, "content-length"), fn value ->
      case Integer.parse(value) do
        {content_length, ""} -> content_length > max_bytes
        _other -> false
      end
    end)
  end
end
