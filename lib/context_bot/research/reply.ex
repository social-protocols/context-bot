defmodule ContextBot.Research.Reply do
  @moduledoc """
  Pure selection of a publishable reply from Anthropic response content.

  Stop reasons may be provider strings or equivalent atoms. Recognized reasons are `end_turn`,
  `max_tokens`, `model_context_window_exceeded`, `refusal`, `pause_turn`, `tool_use`, and
  `stop_sequence`; unknown values fail closed.

  Paired `code_execution` / `bash_code_execution` / `text_editor_code_execution` blocks are
  protocol, not reply text. A failed runtime result is terminal (`:code_execution_failed`) and
  must not compact, split, or publish. See `knowledge-base/reports/2026-08-27-code-execution-hard-fail.md`.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Research.{Citations, ReplyLimits}

  @hard_max_graphemes ReplyLimits.hard_max_graphemes()
  @max_bytes ReplyLimits.max_bytes()
  @web_server_tools ~w(web_search web_fetch)
  # Dated web_search/web_fetch default `allowed_callers` to auto-provisioned code execution.
  # Requests pin `allowed_callers: ["direct"]` so searches are native `server_tool_use` only.
  # If an envelope still contains a code-execution pair, pairing is required protocol; a failed
  # execution (non-zero return_code, *_tool_result_error, or timeout) is a hard failure.
  @code_execution_tools ~w(code_execution bash_code_execution text_editor_code_execution)
  @code_execution_runtime_tools ~w(code_execution bash_code_execution)
  @allowed_server_tools @web_server_tools ++ @code_execution_tools
  @code_execution_result_types ~w(
    code_execution_tool_result
    bash_code_execution_tool_result
    text_editor_code_execution_tool_result
  )
  # Structured outputs sometimes double-escape JSON (`\\u2014` in the source).
  # After Jason.decode those leftover six characters are still `\uXXXX`.
  @json_unicode_escape ~r/\\u([0-9a-fA-F]{4})/

  @type reason :: atom() | {atom(), term()}
  @type server_tool_name :: String.t()
  @type selection_context :: %{
          required(:stop_reason) => term(),
          required(:pending_server_tools) => %{optional(String.t()) => server_tool_name()},
          optional(:seen_server_tool_ids) => MapSet.t(String.t())
        }
  @type selected :: %{
          text: String.t(),
          full_response: String.t(),
          document_title: String.t(),
          disposition: :reply | :no_reply
        }
  @type result ::
          {:ok, selected()}
          | {:title_rewrite, selected()}
          | {:repairable, String.t(), [reason()]}
          | {:split, String.t(), String.t()}
          | {:error, reason()}

  @doc """
  Concatenates final model-authored text in order and classifies it for publication or local split.

  A bare stop reason means there are no server-tool calls pending from an earlier response. For a
  continued `pause_turn`, pass `%{stop_reason: reason, pending_server_tools: %{id => name}}` so a
  leading result block can complete the prior `web_search`, `web_fetch`, `code_execution`,
  `bash_code_execution`, or `text_editor_code_execution` call.
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

  @type writeup :: %{text: String.t(), citations: [map()]}

  @doc """
  Extracts the unstructured research writeup and citation blocks after tool protocol checks.

  Empty writeup text is allowed so a later cheap structure call can return `no_reply`.
  """
  @spec select_writeup([map()], term() | selection_context()) ::
          {:ok, writeup()} | {:error, reason()}
  def select_writeup(
        content_blocks,
        %{stop_reason: stop_reason, pending_server_tools: pending_server_tools} = context
      )
      when is_map(pending_server_tools) do
    seen_tool_ids =
      Map.get(context, :seen_server_tool_ids, MapSet.new(Map.keys(pending_server_tools)))

    if valid_pending_server_tools?(pending_server_tools) and
         valid_seen_tool_ids?(seen_tool_ids, pending_server_tools) do
      select_writeup_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids)
    else
      {:error, :invalid_content}
    end
  end

  def select_writeup(content_blocks, stop_reason),
    do: select_writeup_response(content_blocks, stop_reason, %{}, MapSet.new())

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
  Returns the full writeup from the first structured assistant turn in a Messages request.

  Over-long compact replies split locally. Callers that still need the
  Standard.site document recover `full_response` from the earlier research turn.
  """
  @spec full_response_from_messages(map() | nil) :: String.t() | nil
  def full_response_from_messages(messages),
    do: structured_field_from_messages(messages, :full_response)

  @doc """
  Returns the Reader title from the first structured assistant turn in a Messages request.
  """
  @spec document_title_from_messages(map() | nil) :: String.t() | nil
  def document_title_from_messages(messages),
    do: structured_field_from_messages(messages, :document_title)

  @doc """
  Classifies an already-selected reply for publication or pack-first split.

  Used after a title rewrite fills a blank `document_title`. Never starts a
  compact-reply Anthropic call.
  """
  @spec classify_selected(selected()) :: {:ok, selected()} | {:repairable, String.t(), [reason()]}
  def classify_selected(%{text: text} = selected) when is_binary(text),
    do: classify_structured(selected)

  @doc """
  Reads a nonempty title from a title-only JSON envelope.
  """
  @spec select_title(map()) :: {:ok, String.t()} | {:error, reason()}
  def select_title(%{"content" => content, "stop_reason" => stop_reason})
      when is_list(content) do
    select_title(content, stop_reason)
  end

  def select_title(_decoded), do: {:error, :invalid_structured_output}

  @spec select_title([map()], term()) :: {:ok, String.t()} | {:error, reason()}

  def select_title(content, stop_reason)
      when is_list(content) and stop_reason in ["end_turn", :end_turn] do
    text = content |> assistant_plain_text() |> String.trim()

    case Jason.decode(text) do
      {:ok, %{"title" => title}} when is_binary(title) ->
        case title |> unescape_json_string_escapes() |> String.trim() do
          "" -> {:error, :invalid_structured_output}
          nonempty -> {:ok, nonempty}
        end

      _invalid ->
        {:error, :invalid_structured_output}
    end
  end

  def select_title(_content, _stop_reason), do: {:error, :invalid_structured_output}

  @doc false
  @spec title_only_response?(map()) :: boolean()
  def title_only_response?(%{"content" => content}) when is_list(content) do
    text = content |> assistant_plain_text() |> String.trim()

    case Jason.decode(text) do
      {:ok, %{"title" => title} = body} when is_binary(title) ->
        not Map.has_key?(body, "compact_reply") and not Map.has_key?(body, "full_response")

      _invalid ->
        false
    end
  end

  def title_only_response?(_decoded), do: false

  @doc """
  Attempts to split text into two parts, each ≤300 graphemes and ≤3,000 bytes
  after customary U+2026 continuation ellipses are applied.

  Packs as much as possible into part 1. The part-1 budget is 299 graphemes and
  2,997 bytes unless that left side already ends with `…` or `...`. The 275
  grapheme prompt target is for the model, not for this split. Boundary kind is
  only a tie-break when two valid packs have the same part-1 length: paragraph
  (blank line), then UAX #29 / English CLDR sentence via `unicode_string`, then
  whitespace. A word-boundary pack near the cap beats a much shorter sentence.
  When part-1 lengths are equal, prefer a pack whose part 2 still has room for
  a leading `…` plus `Post.link_suffix/0`. Never cut mid-word or mid-grapheme
  cluster.

  Returns `{:ok, part1, part2}` on success, with part 1 ending in `…` and part 2
  starting with `…` unless that side already had `…` or `...`. Returns `:error`
  if no valid split exists (e.g., a single unbreakable token over 300 graphemes).
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

  @doc """
  Adds customary U+2026 continuation markers to a two-body Bluesky split.

  Idempotent when a side already ends or starts with `…` or `...`. Does not
  insert a space unless that side already begins with whitespace.
  """
  @spec with_continuation_ellipses(String.t(), String.t()) :: {String.t(), String.t()}
  def with_continuation_ellipses(part1, part2)
      when is_binary(part1) and is_binary(part2) do
    {with_trailing_ellipsis(part1), with_leading_ellipsis(part2)}
  end

  defp try_split(text) do
    candidates =
      paragraph_candidates(text) ++ sentence_candidates(text) ++ whitespace_candidates(text)

    pick_best_candidate(candidates)
  end

  defp paragraph_candidates(text) do
    case String.split(text, "\n\n") do
      [_single] -> []
      parts -> joined_candidates(parts, "\n\n", :paragraph)
    end
  end

  # UAX #29 sentence breaks with English CLDR suppressions (U.S., Mr., e.g., …).
  # Inv 15 chopped at "U.S. " because raw ". " / ".\n" matching treated that
  # period as a break. Do not treat a short sentence that fits as a winner when
  # a later whitespace pack fills more of the 300-grapheme cap.
  defp sentence_candidates(text) do
    case Unicode.String.split(text, break: :sentence, locale: "en", trim: true) do
      parts when is_list(parts) and length(parts) >= 2 ->
        joined_candidates(parts, "", :sentence)

      _error_or_single ->
        []
    end
  end

  defp joined_candidates(parts, joiner, kind) do
    max_count = length(parts) - 1

    Enum.flat_map(1..max_count, fn count ->
      left = parts |> Enum.take(count) |> Enum.join(joiner)
      right = parts |> Enum.drop(count) |> Enum.join(joiner)
      List.wrap(build_candidate(left, right, kind))
    end)
  end

  defp whitespace_candidates(text) do
    graphemes = String.graphemes(text)

    graphemes
    |> whitespace_split_indices()
    |> Enum.flat_map(fn split_index ->
      {left_graphemes, right_graphemes} = Enum.split(graphemes, split_index)
      left = Enum.join(left_graphemes)
      right = right_graphemes |> Enum.join() |> String.trim_leading()
      List.wrap(build_candidate(left, right, :whitespace))
    end)
  end

  defp whitespace_split_indices(graphemes) do
    graphemes
    |> Enum.with_index()
    |> Enum.filter(fn {char, _idx} -> char in [" ", "\n", "\t"] end)
    |> Enum.map(fn {_char, idx} -> idx + 1 end)
  end

  defp build_candidate(left, right, kind) do
    left = String.trim(left)
    right = String.trim(right)

    if valid_split_parts?(left, right) do
      %{
        part1: left,
        part2: right,
        part1_len: String.length(left),
        kind: kind,
        link_room: part2_has_link_room?(right)
      }
    end
  end

  defp pick_best_candidate([]), do: :error

  defp pick_best_candidate(candidates) do
    best = Enum.max_by(candidates, &score_candidate/1)
    {part1, part2} = with_continuation_ellipses(best.part1, best.part2)
    {:ok, part1, part2}
  end

  # Maximize part 1. Link-room and boundary kind are exact-length tie-breaks only.
  defp score_candidate(candidate) do
    link_room = if candidate.link_room, do: 1, else: 0
    {candidate.part1_len, link_room, boundary_rank(candidate.kind)}
  end

  defp boundary_rank(:paragraph), do: 3
  defp boundary_rank(:sentence), do: 2
  defp boundary_rank(:whitespace), do: 1

  defp part2_has_link_room?(text) when is_binary(text) do
    ReplyLimits.fits_one_post?(with_leading_ellipsis(text) <> Post.link_suffix())
  end

  defp valid_split_parts?(left, right) do
    if left == "" or right == "" do
      false
    else
      {part1, part2} = with_continuation_ellipses(left, right)
      ReplyLimits.fits_one_post?(part1) and ReplyLimits.fits_one_post?(part2)
    end
  end

  defp with_trailing_ellipsis(text) do
    if ends_with_ellipsis?(text), do: text, else: text <> ReplyLimits.continuation_ellipsis()
  end

  defp with_leading_ellipsis(text) do
    if starts_with_ellipsis?(text), do: text, else: ReplyLimits.continuation_ellipsis() <> text
  end

  defp ends_with_ellipsis?(text),
    do:
      String.ends_with?(text, ReplyLimits.continuation_ellipsis()) or
        String.ends_with?(text, "...")

  defp starts_with_ellipsis?(text),
    do:
      String.starts_with?(text, ReplyLimits.continuation_ellipsis()) or
        String.starts_with?(text, "...")

  defp select_writeup_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids)
       when is_list(content_blocks) and stop_reason in ["end_turn", :end_turn] do
    case content_text(content_blocks, pending_server_tools, seen_tool_ids) do
      {:ok, text} ->
        {:ok,
         %{
           text: String.trim(text),
           citations: Citations.from_content(content_blocks)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_writeup_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids),
    do: select_response(content_blocks, stop_reason, pending_server_tools, seen_tool_ids)

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
      is_binary(id) and id != "" and name in @allowed_server_tools
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
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => input},
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(input) and name in @code_execution_tools do
    add_pending_tool(id, name, texts, pending, prior_pending, seen_tool_ids)
  end

  defp collect_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => _input},
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and name in @web_server_tools do
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
         %{"type" => type, "tool_use_id" => id, "content" => content},
         {:ok, texts, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(content) and
              type in @code_execution_result_types do
    name = code_execution_tool_name(type)

    case classify_code_execution_result(name, content) do
      :ok ->
        complete_tool(id, name, texts, pending, prior_pending, seen_tool_ids)

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
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
              "web_fetch_tool_result" | @code_execution_result_types
            ],
       do: {:halt, {:error, :invalid_content}}

  defp collect_block(%{"type" => "server_tool_use", "name" => name}, _state)
       when is_binary(name) and name not in @allowed_server_tools,
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

  defp code_execution_tool_name("code_execution_tool_result"), do: "code_execution"
  defp code_execution_tool_name("bash_code_execution_tool_result"), do: "bash_code_execution"

  defp code_execution_tool_name("text_editor_code_execution_tool_result"),
    do: "text_editor_code_execution"

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
         %{"type" => type, "tool_use_id" => id, "content" => content},
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(content) and
              type in @code_execution_result_types do
    complete_saved_tool(
      id,
      code_execution_tool_name(type),
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
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => input},
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and is_map(input) and name in @code_execution_tools do
    add_saved_tool(id, name, pending, prior_pending, seen_tool_ids)
  end

  defp validate_saved_block(
         %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => _input},
         {:ok, pending, prior_pending, seen_tool_ids}
       )
       when is_binary(id) and id != "" and name in @web_server_tools do
    add_saved_tool(id, name, pending, prior_pending, seen_tool_ids)
  end

  defp validate_saved_block(%{"type" => "server_tool_use", "name" => name}, _state)
       when is_binary(name) and name not in @allowed_server_tools,
       do: {:halt, {:error, :unexpected_tool_use}}

  defp validate_saved_block(%{"type" => "server_tool_use"}, _state),
    do: {:halt, {:error, :invalid_content}}

  defp validate_saved_block(%{"type" => "tool_use"}, _state),
    do: {:halt, {:error, :unexpected_tool_use}}

  defp validate_saved_block(%{"type" => type}, _state)
       when type in [
              "web_search_tool_result",
              "web_fetch_tool_result" | @code_execution_result_types
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
    with :ok <- validate_result_content(expected_name, content),
         {:ok, ^expected_name} <- Map.fetch(pending, id) do
      {:cont, {:ok, Map.delete(pending, id), Map.delete(prior_pending, id), seen_tool_ids}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
      _missing_or_mismatched -> {:halt, {:error, :unexpected_tool_use}}
    end
  end

  defp validate_result_content(name, content) when name in @code_execution_tools,
    do: classify_code_execution_result(name, content)

  defp validate_result_content(name, content) do
    if valid_tool_result_content?(name, content) do
      :ok
    else
      {:error, :invalid_content}
    end
  end

  # Successful return_code 0 (including a negative research finding in stdout) is publishable.
  # Missing return_code is treated as success so opaque/dynamic-filtering envelopes that omit it
  # still pair. Present non-zero or non-integer return_code, documented *_tool_result_error
  # payloads, and timeout/crash error_codes are terminal.
  defp classify_code_execution_result(name, content)
       when name in @code_execution_tools and is_map(content) do
    if code_execution_failed?(name, content) do
      {:error, :code_execution_failed}
    else
      :ok
    end
  end

  defp classify_code_execution_result(_name, _content), do: {:error, :invalid_content}

  defp code_execution_failed?(name, content) do
    code_execution_error_payload?(content) or
      (name in @code_execution_runtime_tools and failed_return_code?(content))
  end

  defp code_execution_error_payload?(%{"type" => type}) when is_binary(type),
    do: String.ends_with?(type, "_error")

  defp code_execution_error_payload?(%{"error_code" => error_code}) when is_binary(error_code),
    do: true

  defp code_execution_error_payload?(_content), do: false

  defp failed_return_code?(%{"return_code" => 0}), do: false
  defp failed_return_code?(%{"return_code" => code}) when is_integer(code), do: true
  defp failed_return_code?(%{"return_code" => code}) when not is_nil(code), do: true
  defp failed_return_code?(_content), do: false

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

  defp valid_tool_result_content?(name, content)
       when name in @code_execution_tools and is_map(content),
       do: true

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

  defp structured_field_from_messages(%{"messages" => messages}, field)
       when is_list(messages) and field in [:full_response, :document_title] do
    Enum.find_value(messages, fn message ->
      case assistant_structured(message) do
        {:ok, selected} -> selected[field]
        :invalid -> nil
      end
    end)
  end

  defp structured_field_from_messages(_messages, _field), do: nil

  defp assistant_structured(%{"role" => "assistant", "content" => content}) do
    case parse_structured_response(assistant_plain_text(content)) do
      {:ok, %{disposition: :no_reply}} -> :invalid
      {:ok, selected} -> {:ok, selected}
      {:title_rewrite, selected} -> {:ok, selected}
      :invalid -> :invalid
    end
  end

  defp assistant_structured(_message), do: :invalid

  defp assistant_plain_text(content) when is_binary(content), do: content

  defp assistant_plain_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> IO.iodata_to_binary()
  end

  defp assistant_plain_text(_content), do: ""

  defp classify_text(text) do
    case String.trim(text) do
      "" ->
        {:error, :empty_reply}

      nonempty ->
        case parse_structured_response(nonempty) do
          {:ok, selected} ->
            classify_structured(selected)

          {:title_rewrite, selected} ->
            {:title_rewrite, selected}

          :invalid ->
            {:error, :invalid_structured_output}
        end
    end
  end

  defp parse_structured_response(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> structured_fields(decoded)
      {:error, _reason} -> :invalid
    end
  end

  defp structured_fields(%{"disposition" => "no_reply"}) do
    {:ok,
     %{
       text: "",
       full_response: "",
       document_title: "",
       disposition: :no_reply
     }}
  end

  defp structured_fields(%{"disposition" => "reply"} = decoded), do: reply_fields(decoded)

  defp structured_fields(%{"disposition" => _other}), do: :invalid

  defp structured_fields(decoded) when is_map(decoded), do: reply_fields(decoded)

  defp structured_fields(_decoded), do: :invalid

  defp reply_fields(%{"title" => title, "compact_reply" => compact_reply} = decoded)
       when is_binary(title) and is_binary(compact_reply) do
    title = title |> String.trim() |> unescape_json_string_escapes()
    compact_reply = compact_reply |> String.trim() |> unescape_json_string_escapes()

    full_response =
      case decoded do
        %{"full_response" => full} when is_binary(full) ->
          full |> String.trim() |> unescape_json_string_escapes()

        _missing ->
          ""
      end

    cond do
      compact_reply == "" ->
        :invalid

      title == "" ->
        {:title_rewrite,
         %{
           text: compact_reply,
           full_response: full_response,
           document_title: "",
           disposition: :reply
         }}

      true ->
        {:ok,
         %{
           text: compact_reply,
           full_response: full_response,
           document_title: title,
           disposition: :reply
         }}
    end
  end

  defp reply_fields(_decoded), do: :invalid

  # Jason already decoded the structured object. Remaining `\uXXXX`, `\n`, `\t`,
  # and `\"` are leftover string escapes from a double-escaped model value.
  # Decode matching sequences only; do not fail closed or re-parse the object.
  defp unescape_json_string_escapes(text) do
    text
    |> unescape_json_unicode_escapes()
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp unescape_json_unicode_escapes(text) do
    Regex.replace(@json_unicode_escape, text, fn _match, hex ->
      <<String.to_integer(hex, 16)::utf8>>
    end)
  end

  defp classify_structured(%{disposition: :no_reply} = selected), do: {:ok, selected}

  defp classify_structured(%{text: compact_reply} = selected) do
    case limit_reasons(compact_reply) do
      [] -> {:ok, Map.put_new(selected, :disposition, :reply)}
      reasons -> {:repairable, compact_reply, reasons}
    end
  end

  defp limit_reasons(text) do
    []
    |> maybe_add_reason(String.length(text) > @hard_max_graphemes, :too_many_graphemes)
    |> maybe_add_reason(byte_size(text) > @max_bytes, :too_many_bytes)
  end

  defp maybe_add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_add_reason(reasons, false, _reason), do: reasons
end
