defmodule ContextBot.Research.Reply do
  @moduledoc """
  Pure selection of a publishable reply from Anthropic response content.

  Stop reasons may be provider strings or equivalent atoms. Recognized reasons are `end_turn`,
  `max_tokens`, `model_context_window_exceeded`, `refusal`, `pause_turn`, `tool_use`, and
  `stop_sequence`; unknown values fail closed.
  """

  @max_graphemes 300
  @max_bytes 3_000

  @type reason :: atom() | {atom(), term()}
  @type result ::
          {:ok, String.t()}
          | {:repairable, String.t(), [reason()]}
          | {:error, reason()}

  @doc """
  Concatenates final model-authored text in order and classifies it for publication or repair.
  """
  @spec select([map()], term()) :: result()
  def select(content_blocks, stop_reason)
      when is_list(content_blocks) and stop_reason in ["end_turn", :end_turn] do
    case content_text(content_blocks) do
      {:ok, text} ->
        classify_text(text)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def select(_content_blocks, stop_reason) when stop_reason in ["end_turn", :end_turn],
    do: {:error, :invalid_content}

  def select(_content_blocks, stop_reason) when stop_reason in ["refusal", :refusal],
    do: {:error, :refusal}

  def select(_content_blocks, stop_reason) when stop_reason in ["max_tokens", :max_tokens],
    do: {:error, :max_tokens}

  def select(_content_blocks, stop_reason)
      when stop_reason in ["model_context_window_exceeded", :model_context_window_exceeded],
      do: {:error, :model_context_window_exceeded}

  def select(_content_blocks, stop_reason) when stop_reason in ["pause_turn", :pause_turn],
    do: {:error, :pause_turn}

  def select(_content_blocks, stop_reason) when stop_reason in ["tool_use", :tool_use],
    do: {:error, :tool_use}

  def select(_content_blocks, stop_reason),
    do: {:error, {:unexpected_stop_reason, stop_reason}}

  defp content_text(content_blocks) do
    content_blocks
    |> Enum.reduce_while({:ok, [], %{}}, &collect_block/2)
    |> case do
      {:ok, text, pending} when map_size(pending) == 0 ->
        {:ok, text |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, _text, _pending} ->
        {:error, :pending_tool_use}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_block(%{"type" => "text", "text" => text}, {:ok, texts, pending})
       when is_binary(text),
       do: {:cont, {:ok, [text | texts], pending}}

  defp collect_block(%{"type" => type}, state)
       when type in ["thinking", "redacted_thinking"],
       do: {:cont, state}

  defp collect_block(%{"type" => "refusal"}, _state), do: {:halt, {:error, :refusal}}

  defp collect_block(%{"type" => "tool_use"}, _state),
    do: {:halt, {:error, :unexpected_tool_use}}

  defp collect_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name},
         {:ok, texts, pending}
       )
       when is_binary(id) and id != "" and name in ["web_search", "web_fetch"] do
    if Map.has_key?(pending, id) do
      {:halt, {:error, :invalid_content}}
    else
      {:cont, {:ok, texts, Map.put(pending, id, name)}}
    end
  end

  defp collect_block(
         %{
           "type" => "web_search_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending}
       )
       when is_binary(id) and id != "" and (is_list(content) or is_map(content)),
       do: complete_tool(id, "web_search", texts, pending)

  defp collect_block(
         %{
           "type" => "web_fetch_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending}
       )
       when is_binary(id) and id != "" and (is_list(content) or is_map(content)),
       do: complete_tool(id, "web_fetch", texts, pending)

  defp collect_block(%{"type" => type}, _state)
       when type in ["web_search_tool_result", "web_fetch_tool_result"],
       do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => "server_tool_use"}, _state),
    do: {:halt, {:error, :unexpected_tool_use}}

  defp collect_block(%{"type" => "text"}, _state), do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => type}, _state) when is_binary(type),
    do: {:halt, {:error, {:unexpected_content_block, type}}}

  defp collect_block(_block, _state), do: {:halt, {:error, :invalid_content}}

  defp complete_tool(id, expected_name, texts, pending) do
    case Map.fetch(pending, id) do
      {:ok, ^expected_name} -> {:cont, {:ok, texts, Map.delete(pending, id)}}
      _missing_or_mismatched -> {:halt, {:error, :unexpected_tool_use}}
    end
  end

  defp classify_text(text) do
    case String.trim(text) do
      "" -> {:error, :empty_reply}
      _nonempty -> classify_limits(text, limit_reasons(text))
    end
  end

  defp classify_limits(text, []), do: {:ok, text}
  defp classify_limits(text, reasons), do: {:repairable, text, reasons}

  defp limit_reasons(text) do
    []
    |> maybe_add_reason(String.length(text) > @max_graphemes, :too_many_graphemes)
    |> maybe_add_reason(byte_size(text) > @max_bytes, :too_many_bytes)
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons
end
