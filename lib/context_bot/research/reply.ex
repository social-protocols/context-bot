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
  @type server_tool_name :: String.t()
  @type selection_context :: %{
          required(:stop_reason) => term(),
          required(:pending_server_tools) => %{optional(String.t()) => server_tool_name()}
        }
  @type result ::
          {:ok, String.t()}
          | {:repairable, String.t(), [reason()]}
          | {:error, reason()}

  @doc """
  Concatenates final model-authored text in order and classifies it for publication or repair.

  A bare stop reason means there are no server-tool calls pending from an earlier response. For a
  continued `pause_turn`, pass `%{stop_reason: reason, pending_server_tools: %{id => name}}` so a
  leading result block can complete the prior `web_search`, `web_fetch`, or `code_execution` call.
  Prior response text is intentionally not accepted here and is never included in the selected
  reply.
  """
  @spec select([map()], term() | selection_context()) :: result()
  def select(
        content_blocks,
        %{stop_reason: stop_reason, pending_server_tools: pending_server_tools}
      )
      when is_map(pending_server_tools) do
    if valid_pending_server_tools?(pending_server_tools) do
      select_response(content_blocks, stop_reason, pending_server_tools)
    else
      {:error, :invalid_content}
    end
  end

  def select(content_blocks, stop_reason), do: select_response(content_blocks, stop_reason, %{})

  defp select_response(content_blocks, stop_reason, pending_server_tools)
       when is_list(content_blocks) and stop_reason in ["end_turn", :end_turn] do
    case content_text(content_blocks, pending_server_tools) do
      {:ok, text} ->
        classify_text(text)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["end_turn", :end_turn],
       do: {:error, :invalid_content}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["refusal", :refusal],
       do: {:error, :refusal}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["max_tokens", :max_tokens],
       do: {:error, :max_tokens}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["model_context_window_exceeded", :model_context_window_exceeded],
       do: {:error, :model_context_window_exceeded}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["pause_turn", :pause_turn],
       do: {:error, :pause_turn}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools)
       when stop_reason in ["tool_use", :tool_use],
       do: {:error, :tool_use}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools),
    do: {:error, {:unexpected_stop_reason, stop_reason}}

  defp content_text(content_blocks, pending_server_tools) do
    content_blocks
    |> Enum.reduce_while(
      {:ok, [], pending_server_tools, pending_server_tools},
      &collect_block/2
    )
    |> case do
      {:ok, text, pending, _prior_pending} when map_size(pending) == 0 ->
        {:ok, text |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, _text, _pending, _prior_pending} ->
        {:error, :pending_tool_use}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_pending_server_tools?(pending_server_tools) do
    Enum.all?(pending_server_tools, fn {id, name} ->
      is_binary(id) and id != "" and name in ["web_search", "web_fetch", "code_execution"]
    end)
  end

  defp collect_block(
         %{"type" => type},
         {:ok, _texts, _pending, prior_pending}
       )
       when map_size(prior_pending) > 0 and
              type in [
                "text",
                "thinking",
                "redacted_thinking",
                "refusal",
                "tool_use",
                "server_tool_use"
              ],
       do: {:halt, {:error, :unexpected_tool_use}}

  defp collect_block(
         %{"type" => "text", "text" => text},
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(text),
       do: {:cont, {:ok, [text | texts], pending, prior_pending}}

  defp collect_block(
         %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
         state
       )
       when is_binary(thinking) and is_binary(signature),
       do: {:cont, state}

  defp collect_block(%{"type" => "redacted_thinking", "data" => data}, state)
       when is_binary(data),
       do: {:cont, state}

  defp collect_block(%{"type" => type}, _state)
       when type in ["thinking", "redacted_thinking"],
       do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => "refusal"}, _state), do: {:halt, {:error, :refusal}}

  defp collect_block(%{"type" => "tool_use"}, _state),
    do: {:halt, {:error, :unexpected_tool_use}}

  defp collect_block(
         %{
           "type" => "server_tool_use",
           "id" => id,
           "name" => "code_execution",
           "input" => input
         },
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(id) and id != "" and is_map(input) do
    add_pending_tool(id, "code_execution", texts, pending, prior_pending)
  end

  defp collect_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => _input},
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(id) and id != "" and name in ["web_search", "web_fetch"] do
    add_pending_tool(id, name, texts, pending, prior_pending)
  end

  defp collect_block(
         %{
           "type" => "web_search_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(id) and id != "" do
    if valid_tool_result_content?("web_search", content) do
      complete_tool(id, "web_search", texts, pending, prior_pending)
    else
      {:halt, {:error, :invalid_content}}
    end
  end

  defp collect_block(
         %{
           "type" => "code_execution_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(id) and id != "" and is_map(content) do
    complete_tool(id, "code_execution", texts, pending, prior_pending)
  end

  defp collect_block(
         %{
           "type" => "web_fetch_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending, prior_pending}
       )
       when is_binary(id) and id != "" do
    if valid_tool_result_content?("web_fetch", content) do
      complete_tool(id, "web_fetch", texts, pending, prior_pending)
    else
      {:halt, {:error, :invalid_content}}
    end
  end

  defp collect_block(%{"type" => type}, _state)
       when type in [
              "web_search_tool_result",
              "web_fetch_tool_result",
              "code_execution_tool_result"
            ],
       do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => "server_tool_use", "name" => name}, _state)
       when is_binary(name) and name not in ["web_search", "web_fetch", "code_execution"],
       do: {:halt, {:error, :unexpected_tool_use}}

  defp collect_block(%{"type" => "server_tool_use"}, _state),
    do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => "text"}, _state), do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => type}, _state) when is_binary(type),
    do: {:halt, {:error, {:unexpected_content_block, type}}}

  defp collect_block(_block, _state), do: {:halt, {:error, :invalid_content}}

  defp add_pending_tool(id, name, texts, pending, prior_pending) do
    if Map.has_key?(pending, id) do
      {:halt, {:error, :invalid_content}}
    else
      {:cont, {:ok, texts, Map.put(pending, id, name), prior_pending}}
    end
  end

  defp complete_tool(id, expected_name, texts, pending, prior_pending) do
    case Map.fetch(pending, id) do
      {:ok, ^expected_name} ->
        {:cont, {:ok, texts, Map.delete(pending, id), Map.delete(prior_pending, id)}}

      _missing_or_mismatched ->
        {:halt, {:error, :unexpected_tool_use}}
    end
  end

  defp valid_tool_result_content?("web_search", content) when is_list(content),
    do: Enum.all?(content, &valid_web_search_result?/1)

  defp valid_tool_result_content?(
         "web_search",
         %{"type" => "web_search_tool_result_error", "error_code" => error_code}
       ),
       do: is_binary(error_code)

  defp valid_tool_result_content?(
         "web_fetch",
         %{
           "type" => "web_fetch_result",
           "url" => url,
           "content" => %{"type" => "document"}
         } = result
       ),
       do: is_binary(url) and valid_optional_retrieved_at?(result)

  defp valid_tool_result_content?(
         "web_fetch",
         %{"type" => "web_fetch_tool_result_error", "error_code" => error_code}
       ),
       do: is_binary(error_code)

  defp valid_tool_result_content?(_tool_name, _content), do: false

  defp valid_optional_retrieved_at?(result) do
    case Map.fetch(result, "retrieved_at") do
      :error -> true
      {:ok, retrieved_at} -> is_binary(retrieved_at) or is_nil(retrieved_at)
    end
  end

  defp valid_web_search_result?(%{
         "type" => "web_search_result",
         "url" => url,
         "title" => title,
         "encrypted_content" => encrypted_content,
         "page_age" => page_age
       }),
       do:
         is_binary(url) and is_binary(title) and is_binary(encrypted_content) and
           (is_binary(page_age) or is_nil(page_age))

  defp valid_web_search_result?(_result), do: false

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
