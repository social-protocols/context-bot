defmodule ContextBot.Logging.JSONFormatter do
  @moduledoc """
  Formats bounded, allowlisted operational Logger events as JSON Lines.
  """

  @safe_metadata MapSet.new(~w(
    invocation_id job_id queue worker attempt attempt_kind attempt_index stage duration_ms
    input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens
    tool_uses web_search_uses cost_microdollars failure_category failure_reason
    request_id method path status status_code examined resumed terminalized unchanged
    media_disposition image_count
  )a)

  @numeric_metadata MapSet.new(~w(
    invocation_id job_id attempt attempt_index duration_ms input_tokens output_tokens
    cache_creation_input_tokens cache_read_input_tokens tool_uses web_search_uses
    cost_microdollars status status_code examined resumed terminalized unchanged
    image_count
  )a)

  @token_metadata MapSet.new(~w(
    queue attempt_kind stage failure_category failure_reason
  )a)

  @safe_messages MapSet.new(~w(context_bot_attempt context_bot_startup_recovery))
  @media_dispositions MapSet.new(~w(supported video_unsupported image_limit_exceeded))
  @token ~r/\A[a-z][a-z0-9_-]{0,127}\z/
  @worker ~r/\AElixir\.[A-Za-z0-9_.]{1,240}\z|\A[A-Z][A-Za-z0-9_.]{1,247}\z/
  @request_id ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @spec format(map(), map()) :: IO.chardata()
  def format(%{level: level, msg: message, meta: metadata}, _config)
      when is_atom(level) and is_map(metadata) do
    base = %{
      timestamp: timestamp(Map.get(metadata, :time)),
      severity: Atom.to_string(level),
      message: safe_message(message)
    }

    metadata
    |> Enum.reduce(base, &put_safe_metadata/2)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _error -> fallback()
  end

  def format(_event, _config), do: fallback()

  defp put_safe_metadata({key, value}, output) do
    if MapSet.member?(@safe_metadata, key) do
      case safe_metadata_value(key, value) do
        {:ok, safe_value} -> Map.put(output, key, safe_value)
        :error -> output
      end
    else
      output
    end
  end

  defp safe_metadata_value(key, value) do
    if MapSet.member?(@numeric_metadata, key),
      do: safe_non_negative(value),
      else: safe_non_numeric_metadata(key, value)
  end

  defp safe_non_numeric_metadata(key, value) do
    if MapSet.member?(@token_metadata, key),
      do: safe_token(value),
      else: safe_named_metadata(key, value)
  end

  defp safe_named_metadata(:worker, value), do: safe_regex(value, @worker)
  defp safe_named_metadata(:request_id, value), do: safe_regex(value, @request_id)
  defp safe_named_metadata(:method, value), do: safe_method(value)
  defp safe_named_metadata(:path, "/health"), do: {:ok, "/health"}

  defp safe_named_metadata(:media_disposition, value) do
    if MapSet.member?(@media_dispositions, value), do: {:ok, value}, else: :error
  end

  defp safe_named_metadata(_key, _value), do: :error

  defp safe_non_negative(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp safe_non_negative(_value), do: :error

  defp safe_regex(value, regex) when is_binary(value) do
    if Regex.match?(regex, value), do: {:ok, value}, else: :error
  end

  defp safe_regex(_value, _regex), do: :error

  defp safe_method(value)
       when value in ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"],
       do: {:ok, value}

  defp safe_method(_value), do: :error

  defp safe_token(value) when is_atom(value), do: safe_token(Atom.to_string(value))

  defp safe_token(value) when is_binary(value) do
    if Regex.match?(@token, value), do: {:ok, value}, else: :error
  end

  defp safe_token(_value), do: :error

  defp safe_message({:string, value}), do: event_name(value)
  defp safe_message(value) when is_atom(value), do: value |> Atom.to_string() |> event_name()
  defp safe_message(value) when is_binary(value), do: event_name(value)
  defp safe_message(_value), do: "logger_event"

  defp event_name(value) when is_binary(value) do
    if MapSet.member?(@safe_messages, value), do: value, else: "logger_event"
  end

  defp event_name(_value), do: "logger_event"

  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value, :microsecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _reason} -> "unknown"
    end
  end

  defp timestamp(_value), do: "unknown"

  defp fallback, do: Jason.encode!(%{severity: "error", message: "logger_format_error"}) <> "\n"
end
