defmodule ContextBot.Research.Reply do
  @moduledoc """
  Pure selection of a publishable reply from Anthropic response content.

  Stop reasons may be provider strings or equivalent atoms. Recognized reasons are `end_turn`,
  `max_tokens`, `model_context_window_exceeded`, `refusal`, `pause_turn`, `tool_use`, and
  `stop_sequence`; unknown values fail closed.
  """

  alias ContextBot.Research.ReplyLimits

  @hard_max_graphemes ReplyLimits.hard_max_graphemes()
  @max_bytes ReplyLimits.max_bytes()

  @type reason :: atom() | {atom(), term()}
  @type server_tool_name :: String.t()
  @type selection_context :: %{
          required(:stop_reason) => term(),
          required(:pending_server_tools) => %{optional(String.t()) => server_tool_name()},
          optional(:seen_server_tool_ids) => MapSet.t(String.t())
        }
  @type result ::
          {:ok, String.t()}
          | {:ok, String.t(), String.t()}
          | {:repairable, String.t(), [reason()]}
          | {:split, String.t(), String.t()}
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
        %{stop_reason: stop_reason, pending_server_tools: pending_server_tools} = context
      )
      when is_map(pending_server_tools) do
    seen_tool_ids =
      Map.get(context, :seen_server_tool_ids, MapSet.new(Map.keys(pending_server_tools)))

    if valid_pending_server_tools?(pending_server_tools) and
         valid_seen_tool_ids?(seen_tool_ids, pending_server_tools) do
      select_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids)
    else
      {:error, :invalid_content}
    end
  end

  def select(content_blocks, stop_reason),
    do: select_response(content_blocks, stop_reason, %{}, MapSet.new())

  @doc "Validates server-tool protocol in saved assistant turns and returns pending/seen state."
  @spec server_tool_context(map(), [map()]) ::
          {:ok,
           %{
             pending_server_tools: %{optional(String.t()) => server_tool_name()},
             seen_server_tool_ids: MapSet.t(String.t())
           }}
          | {:error, reason()}
  def server_tool_context(request, additional_content \\ [])

  def server_tool_context(%{"messages" => messages}, additional_content)
      when is_list(messages) and is_list(additional_content) do
    contents =
      Enum.flat_map(messages, fn
        %{"role" => "assistant", "content" => content} when is_list(content) -> [content]
        _message -> []
      end) ++ [additional_content]

    Enum.reduce_while(contents, {:ok, %{}, MapSet.new()}, fn content,
                                                             {:ok, pending, seen_tool_ids} ->
      case validate_saved_content(content, pending, seen_tool_ids) do
        {:ok, next_pending, next_seen} ->
          {:cont, {:ok, next_pending, next_seen}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pending, seen_tool_ids} ->
        {:ok, %{pending_server_tools: pending, seen_server_tool_ids: seen_tool_ids}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def server_tool_context(_request, _additional_content), do: {:error, :invalid_content}

  @doc """
  Attempts to split text into two parts, each ≤300 graphemes and ≤3,000 bytes.

  Prefers paragraph breaks (double newline), then sentence breaks (period + space/newline),
  then any whitespace boundary. Returns `{:ok, part1, part2}` on success or `:error` if
  no valid split exists (e.g., single unbreakable chunk over 300 graphemes).
  """
  @spec split_text(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_text(text) when is_binary(text) do
    graphemes = String.length(text)

    if graphemes <= @hard_max_graphemes do
      :error
    else
      try_split(text)
    end
  end

  defp try_split(text) do
    with :error <- try_split_at_paragraph(text),
         :error <- try_split_at_sentence(text) do
      try_split_at_whitespace(text)
    end
  end

  defp try_split_at_paragraph(text) do
    case String.split(text, "\n\n", parts: 2) do
      [_single] ->
        :error

      [left, right] ->
        validate_split_parts(left, right)
    end
  end

  defp try_split_at_sentence(text) do
    case :binary.matches(text, [". ", ".\n"]) do
      [] ->
        :error

      matches ->
        find_best_sentence_split(text, matches)
    end
  end

  defp find_best_sentence_split(text, matches) do
    byte_length = byte_size(text)
    target_byte = div(byte_length, 2)

    best_match =
      Enum.min_by(matches, fn {pos, _len} ->
        abs(pos - target_byte)
      end)

    {pos, len} = best_match
    split_pos = pos + len

    left = binary_part(text, 0, split_pos)
    right = binary_part(text, split_pos, byte_length - split_pos)

    validate_split_parts(left, right)
  end

  defp try_split_at_whitespace(text) do
    grapheme_length = String.length(text)
    target_grapheme = div(grapheme_length, 2)

    text
    |> String.graphemes()
    |> find_whitespace_near_midpoint(target_grapheme)
    |> case do
      nil ->
        :error

      split_index ->
        {left_graphemes, right_graphemes} = Enum.split(String.graphemes(text), split_index)
        left = Enum.join(left_graphemes)
        right = Enum.join(right_graphemes) |> String.trim_leading()
        validate_split_parts(left, right)
    end
  end

  defp find_whitespace_near_midpoint(graphemes, target) do
    indexed = Enum.with_index(graphemes)

    whitespace_indices =
      Enum.filter(indexed, fn {char, _idx} -> char in [" ", "\n", "\t"] end)
      |> Enum.map(fn {_char, idx} -> idx + 1 end)

    case whitespace_indices do
      [] ->
        nil

      indices ->
        Enum.min_by(indices, fn idx -> abs(idx - target) end)
    end
  end

  defp validate_split_parts(left, right) do
    left = String.trim(left)
    right = String.trim(right)

    left_graphemes = String.length(left)
    right_graphemes = String.length(right)
    left_bytes = byte_size(left)
    right_bytes = byte_size(right)

    if left_graphemes > 0 and left_graphemes <= @hard_max_graphemes and
         left_bytes <= @max_bytes and
         right_graphemes > 0 and right_graphemes <= @hard_max_graphemes and
         right_bytes <= @max_bytes do
      {:ok, left, right}
    else
      :error
    end
  end

  defp select_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids)
       when is_list(content_blocks) and stop_reason in ["end_turn", :end_turn] do
    case content_text(content_blocks, pending_server_tools, seen_tool_ids) do
      {:ok, text} ->
        classify_text(text)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["end_turn", :end_turn],
       do: {:error, :invalid_content}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["refusal", :refusal],
       do: {:error, :refusal}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["max_tokens", :max_tokens],
       do: {:error, :max_tokens}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["model_context_window_exceeded", :model_context_window_exceeded],
       do: {:error, :model_context_window_exceeded}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["pause_turn", :pause_turn],
       do: {:error, :pause_turn}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids)
       when stop_reason in ["tool_use", :tool_use],
       do: {:error, :tool_use}

  defp select_response(_content_blocks, stop_reason, _pending_server_tools, _seen_tool_ids),
    do: {:error, {:unexpected_stop_reason, stop_reason}}

  defp content_text(content_blocks, pending_server_tools, seen_tool_ids) do
    content_blocks
    |> Enum.reduce_while(
      {:ok, [], pending_server_tools, pending_server_tools, seen_tool_ids},
      &collect_block/2
    )
    |> case do
      {:ok, text, pending, _prior_pending, _seen_tool_ids} when map_size(pending) == 0 ->
        {:ok, text |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, _text, _pending, _prior_pending, _seen_tool_ids} ->
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

  defp valid_seen_tool_ids?(%MapSet{} = seen_tool_ids, pending_server_tools) do
    Enum.all?(pending_server_tools, fn {id, _name} -> MapSet.member?(seen_tool_ids, id) end)
  end

  defp valid_seen_tool_ids?(_seen_tool_ids, _pending_server_tools), do: false

  defp collect_block(
         %{"type" => type},
         {:ok, _texts, _pending, prior_pending, _seen_tool_ids}
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
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(text),
       do: {:cont, {:ok, [text | texts], pending, prior_pending, seen_tool_ids}}

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
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(input) do
    add_pending_tool(id, "code_execution", texts, pending, prior_pending, seen_tool_ids)
  end

  defp collect_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => _input},
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and name in ["web_search", "web_fetch"] do
    add_pending_tool(id, name, texts, pending, prior_pending, seen_tool_ids)
  end

  defp collect_block(
         %{
           "type" => "web_search_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" do
    if valid_tool_result_content?("web_search", content) do
      complete_tool(id, "web_search", texts, pending, prior_pending, seen_tool_ids)
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
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(content) do
    complete_tool(id, "code_execution", texts, pending, prior_pending, seen_tool_ids)
  end

  defp collect_block(
         %{
           "type" => "web_fetch_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" do
    if valid_tool_result_content?("web_fetch", content) do
      complete_tool(id, "web_fetch", texts, pending, prior_pending, seen_tool_ids)
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

  defp add_pending_tool(id, name, texts, pending, prior_pending, seen_tool_ids) do
    if MapSet.member?(seen_tool_ids, id) do
      {:halt, {:error, :invalid_content}}
    else
      {:cont,
       {:ok, texts, Map.put(pending, id, name), prior_pending, MapSet.put(seen_tool_ids, id)}}
    end
  end

  defp complete_tool(id, expected_name, texts, pending, prior_pending, seen_tool_ids) do
    case Map.fetch(pending, id) do
      {:ok, ^expected_name} ->
        {:cont,
         {:ok, texts, Map.delete(pending, id), Map.delete(prior_pending, id), seen_tool_ids}}

      _missing_or_mismatched ->
        {:halt, {:error, :unexpected_tool_use}}
    end
  end

  defp validate_saved_content(content, pending, seen_tool_ids) do
    content
    |> Enum.reduce_while(
      {:ok, pending, pending, seen_tool_ids},
      &validate_saved_block/2
    )
    |> case do
      {:ok, next_pending, _prior_pending, next_seen} ->
        {:ok, next_pending, next_seen}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_saved_block(
         %{
           "type" => "web_search_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" do
    complete_saved_tool(
      id,
      "web_search",
      content,
      pending,
      prior_pending,
      seen_tool_ids
    )
  end

  defp validate_saved_block(
         %{
           "type" => "web_fetch_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" do
    complete_saved_tool(
      id,
      "web_fetch",
      content,
      pending,
      prior_pending,
      seen_tool_ids
    )
  end

  defp validate_saved_block(
         %{
           "type" => "code_execution_tool_result",
           "tool_use_id" => id,
           "content" => content
         },
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(content) do
    complete_saved_tool(
      id,
      "code_execution",
      content,
      pending,
      prior_pending,
      seen_tool_ids
    )
  end

  defp validate_saved_block(
         _block,
         {:ok, _pending, prior_pending, _seen_tool_ids}
       )
       when map_size(prior_pending) > 0,
       do: {:halt, {:error, :unexpected_tool_use}}

  defp validate_saved_block(
         %{
           "type" => "server_tool_use",
           "id" => id,
           "name" => "code_execution",
           "input" => input
         },
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(input) do
    add_saved_tool(id, "code_execution", pending, prior_pending, seen_tool_ids)
  end

  defp validate_saved_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => _input},
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and name in ["web_search", "web_fetch"] do
    add_saved_tool(id, name, pending, prior_pending, seen_tool_ids)
  end

  defp validate_saved_block(%{"type" => "server_tool_use", "name" => name}, _state)
       when is_binary(name) and name not in ["web_search", "web_fetch", "code_execution"],
       do: {:halt, {:error, :unexpected_tool_use}}

  defp validate_saved_block(%{"type" => "server_tool_use"}, _state),
    do: {:halt, {:error, :invalid_content}}

  defp validate_saved_block(%{"type" => "tool_use"}, _state),
    do: {:halt, {:error, :unexpected_tool_use}}

  defp validate_saved_block(%{"type" => type}, _state)
       when type in [
              "web_search_tool_result",
              "web_fetch_tool_result",
              "code_execution_tool_result"
            ],
       do: {:halt, {:error, :invalid_content}}

  defp validate_saved_block(_opaque_provider_block, state), do: {:cont, state}

  defp add_saved_tool(id, name, pending, prior_pending, seen_tool_ids) do
    if MapSet.member?(seen_tool_ids, id) do
      {:halt, {:error, :invalid_content}}
    else
      {:cont, {:ok, Map.put(pending, id, name), prior_pending, MapSet.put(seen_tool_ids, id)}}
    end
  end

  defp complete_saved_tool(
         id,
         expected_name,
         content,
         pending,
         prior_pending,
         seen_tool_ids
       ) do
    with true <- valid_tool_result_content?(expected_name, content),
         {:ok, ^expected_name} <- Map.fetch(pending, id) do
      {:cont, {:ok, Map.delete(pending, id), Map.delete(prior_pending, id), seen_tool_ids}}
    else
      false -> {:halt, {:error, :invalid_content}}
      _missing_or_mismatched -> {:halt, {:error, :unexpected_tool_use}}
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

  defp valid_tool_result_content?("code_execution", content) when is_map(content), do: true

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
      "" ->
        {:error, :empty_reply}

      nonempty ->
        case parse_dual_response(nonempty) do
          {:ok, full_response, compact_reply} ->
            classify_dual(full_response, compact_reply, limit_reasons(compact_reply))

          :not_dual_format ->
            classify_limits(text, limit_reasons(text))
        end
    end
  end

  defp parse_dual_response(text) do
    separator = "\n---COMPACT_REPLY---\n"

    case String.split(text, separator, parts: 2) do
      [full_response, compact_reply] when byte_size(full_response) > 0 ->
        trimmed_full = String.trim(full_response)
        trimmed_compact = String.trim(compact_reply)

        if trimmed_full != "" and trimmed_compact != "" do
          {:ok, trimmed_full, trimmed_compact}
        else
          :not_dual_format
        end

      _ ->
        :not_dual_format
    end
  end

  defp classify_dual(full_response, compact_reply, []) when byte_size(full_response) > 0,
    do: {:ok, full_response, compact_reply}

  defp classify_dual(full_response, compact_reply, reasons) when byte_size(full_response) > 0,
    do: {:repairable, compact_reply, reasons}

  defp classify_limits(text, []), do: {:ok, text}
  defp classify_limits(text, reasons), do: {:repairable, text, reasons}

  defp limit_reasons(text) do
    []
    |> maybe_add_reason(String.length(text) > @hard_max_graphemes, :too_many_graphemes)
    |> maybe_add_reason(byte_size(text) > @max_bytes, :too_many_bytes)
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons
end
