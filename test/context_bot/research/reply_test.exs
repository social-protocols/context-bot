defmodule ContextBot.Research.ReplyTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Reply

  test "accepts ordered model text at exactly 300 graphemes and 3,000 bytes" do
    reply =
      String.duplicate("👩‍💻", 268) <>
        String.duplicate("e\u0301", 8) <>
        String.duplicate("é", 4) <>
        String.duplicate("a", 20)

    assert String.length(reply) == 300
    assert byte_size(reply) == 3_000

    {first, second} = String.split_at(reply, 150)

    content = [
      %{"type" => "text", "text" => first},
      %{"type" => "text", "text" => second}
    ]

    assert Reply.select(content, "end_turn") == {:ok, reply}
  end

  test "ignores opaque thinking and completed expected server-tool blocks" do
    content = [
      %{"type" => "thinking", "thinking" => "opaque", "signature" => "signed"},
      %{"type" => "text", "text" => "First "},
      %{
        "type" => "server_tool_use",
        "id" => "search-1",
        "name" => "web_search",
        "input" => %{"query" => "claim"}
      },
      %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "search-1",
        "content" => [
          %{
            "type" => "web_search_result",
            "url" => "https://example.test/search-result",
            "title" => "Search result",
            "encrypted_content" => "opaque-search-result",
            "page_age" => nil
          }
        ]
      },
      %{"type" => "redacted_thinking", "data" => "opaque-ciphertext"},
      %{
        "type" => "server_tool_use",
        "id" => "fetch-1",
        "name" => "web_fetch",
        "input" => %{"url" => "https://example.test"}
      },
      %{
        "type" => "web_fetch_tool_result",
        "tool_use_id" => "fetch-1",
        "content" => %{
          "type" => "web_fetch_result",
          "url" => "https://example.test",
          "content" => %{"type" => "document", "opaque" => "opaque-fetch"},
          "retrieved_at" => nil
        }
      },
      %{"type" => "text", "text" => "second."}
    ]

    assert Reply.select(content, :end_turn) == {:ok, "First second."}
  end

  test "accepts paired dynamic-filtering code execution while selecting only model text" do
    content = [
      %{"type" => "thinking", "thinking" => "opaque", "signature" => "signed"},
      %{
        "type" => "server_tool_use",
        "id" => "code-1",
        "name" => "code_execution",
        "input" => %{"code" => "opaque provider program"}
      },
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "code-1",
        "content" => %{
          "type" => "encrypted_code_execution_result",
          "encrypted_stdout" => "opaque",
          "stderr" => "",
          "return_code" => 0,
          "content" => []
        }
      },
      text("First "),
      text("second.")
    ]

    assert Reply.select(content, :end_turn) == {:ok, "First second."}
  end

  test "fails closed on malformed, duplicate, mismatched, and orphaned code execution blocks" do
    call = %{
      "type" => "server_tool_use",
      "id" => "code-1",
      "name" => "code_execution",
      "input" => %{"code" => "opaque"}
    }

    result = %{
      "type" => "code_execution_tool_result",
      "tool_use_id" => "code-1",
      "content" => %{"type" => "code_execution_result"}
    }

    invalid_content = [
      [Map.delete(call, "id"), result, text("must not publish")],
      [Map.put(call, "id", ""), result, text("must not publish")],
      [Map.put(call, "input", "not-a-map"), result, text("must not publish")],
      [call, Map.delete(result, "content"), text("must not publish")],
      [call, Map.put(result, "content", []), text("must not publish")],
      [call, Map.put(result, "tool_use_id", "other"), text("must not publish")],
      [call, call, result, text("must not publish")],
      [call, result, call, result, text("must not publish")],
      [result, text("must not publish")]
    ]

    Enum.each(invalid_content, fn content ->
      assert {:error, _reason} = Reply.select(content, :end_turn)
    end)
  end

  test "completes code execution started in a prior pause" do
    completed_content = [
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "paused-code-1",
        "content" => %{"type" => "code_execution_result", "content" => []}
      },
      text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-code-1" => "code_execution"}
    }

    assert Reply.select(completed_content, context) == {:ok, "Final context only."}
  end

  test "completes a server tool started in a prior pause without publishing prior partial text" do
    paused_content = [
      text("Partial pre-pause narration must not publish. "),
      %{
        "type" => "server_tool_use",
        "id" => "paused-fetch-1",
        "name" => "web_fetch",
        "input" => %{"url" => "https://example.test/live"}
      }
    ]

    assert List.first(paused_content)["text"] =~ "must not publish"

    completed_content = [
      %{
        "type" => "web_fetch_tool_result",
        "tool_use_id" => "paused-fetch-1",
        "content" => %{
          "type" => "web_fetch_result",
          "url" => "https://example.test/live",
          "content" => %{"type" => "document", "opaque" => %{"future" => true}}
        }
      },
      text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-fetch-1" => "web_fetch"}
    }

    assert Reply.select(completed_content, context) == {:ok, "Final context only."}
  end

  test "rejects mismatched, unknown, orphaned, and still-pending cross-response tools" do
    fetch_success = %{
      "type" => "web_fetch_tool_result",
      "tool_use_id" => "paused-call-1",
      "content" => %{
        "type" => "web_fetch_result",
        "url" => "https://example.test/page",
        "content" => %{"type" => "document"},
        "retrieved_at" => nil
      }
    }

    assert Reply.select(
             [fetch_success, text("must not publish")],
             %{
               stop_reason: :end_turn,
               pending_server_tools: %{"paused-call-1" => "web_search"}
             }
           ) == {:error, :unexpected_tool_use}

    assert Reply.select(
             [%{"type" => "future_tool_result", "tool_use_id" => "paused-call-1"}],
             %{
               stop_reason: :end_turn,
               pending_server_tools: %{"paused-call-1" => "web_fetch"}
             }
           ) == {:error, {:unexpected_content_block, "future_tool_result"}}

    assert Reply.select(
             [fetch_success],
             %{
               stop_reason: :end_turn,
               pending_server_tools: %{"different-call" => "web_fetch"}
             }
           ) == {:error, :unexpected_tool_use}

    assert Reply.select(
             [fetch_success],
             %{
               stop_reason: :end_turn,
               pending_server_tools: %{
                 "paused-call-1" => "web_fetch",
                 "paused-call-2" => "web_search"
               }
             }
           ) == {:error, :pending_tool_use}

    assert Reply.select(
             [text("must not publish"), fetch_success, text("nor this")],
             %{
               stop_reason: :end_turn,
               pending_server_tools: %{"paused-call-1" => "web_fetch"}
             }
           ) == {:error, :unexpected_tool_use}
  end

  test "rejects malformed pending server-tool context" do
    invalid_pending_maps = [
      %{123 => "web_search"},
      %{"" => "web_search"},
      %{"call-1" => "future_tool"}
    ]

    Enum.each(invalid_pending_maps, fn pending_server_tools ->
      assert Reply.select([text("must not publish")], %{
               stop_reason: :end_turn,
               pending_server_tools: pending_server_tools
             }) == {:error, :invalid_content}
    end)
  end

  test "accepts replies between prompt target and hard cap without repair" do
    at_276 = String.duplicate("a", 276)
    at_280 = String.duplicate("a", 280)
    at_300 = String.duplicate("a", 300)

    assert String.length(at_276) == 276
    assert String.length(at_280) == 280
    assert String.length(at_300) == 300

    assert Reply.select([text(at_276)], "end_turn") == {:ok, at_276}
    assert Reply.select([text(at_280)], "end_turn") == {:ok, at_280}
    assert Reply.select([text(at_300)], "end_turn") == {:ok, at_300}
  end

  test "classifies over-limit normal completions as repairable without truncating" do
    over_graphemes = String.duplicate("a", 301)
    over_bytes = String.duplicate("👩‍💻", 272) <> String.duplicate("a", 9)
    over_both = String.duplicate("👩‍💻", 301)

    assert String.length(over_graphemes) == 301
    assert byte_size(over_bytes) == 3_001
    assert String.length(over_bytes) == 281

    assert Reply.select([text(over_graphemes)], "end_turn") ==
             {:repairable, over_graphemes, [:too_many_graphemes]}

    assert Reply.select([text(over_bytes)], "end_turn") ==
             {:repairable, over_bytes, [:too_many_bytes]}

    assert Reply.select([text(over_both)], "end_turn") ==
             {:repairable, over_both, [:too_many_graphemes, :too_many_bytes]}
  end

  test "rejects empty or whitespace-only normal completions as terminal" do
    for content <- [
          [],
          [text("")],
          [text(" \n\t")],
          [%{"type" => "thinking", "thinking" => "opaque", "signature" => "signed"}]
        ] do
      assert Reply.select(content, :end_turn) == {:error, :empty_reply}
    end
  end

  test "treats refusal and every incomplete or unknown stop reason as terminal" do
    cases = [
      {"refusal", :refusal},
      {:refusal, :refusal},
      {"max_tokens", :max_tokens},
      {:max_tokens, :max_tokens},
      {"model_context_window_exceeded", :model_context_window_exceeded},
      {:model_context_window_exceeded, :model_context_window_exceeded},
      {"pause_turn", :pause_turn},
      {:pause_turn, :pause_turn},
      {"tool_use", :tool_use},
      {:tool_use, :tool_use},
      {"stop_sequence", {:unexpected_stop_reason, "stop_sequence"}},
      {:stop_sequence, {:unexpected_stop_reason, :stop_sequence}},
      {nil, {:unexpected_stop_reason, nil}},
      {"future_stop", {:unexpected_stop_reason, "future_stop"}}
    ]

    Enum.each(cases, fn {stop_reason, terminal_reason} ->
      assert Reply.select([text(String.duplicate("partial", 100))], stop_reason) ==
               {:error, terminal_reason}
    end)
  end

  test "rejects pending, client, unexpected, or orphaned tool use as terminal" do
    cases = [
      {[%{"type" => "tool_use", "id" => "client-1", "name" => "local_tool"}],
       :unexpected_tool_use},
      {[
         %{
           "type" => "server_tool_use",
           "id" => "pending-1",
           "name" => "web_search",
           "input" => %{"query" => "claim"}
         }
       ], :pending_tool_use},
      {[
         %{
           "type" => "server_tool_use",
           "id" => "unexpected-1",
           "name" => "future_server_tool",
           "input" => %{}
         }
       ], :unexpected_tool_use},
      {[
         %{
           "type" => "web_search_tool_result",
           "tool_use_id" => "missing-call",
           "content" => []
         }
       ], :unexpected_tool_use}
    ]

    Enum.each(cases, fn {content, reason} ->
      assert Reply.select(content, "end_turn") == {:error, reason}
    end)
  end

  test "fails closed on refusal, unknown, and malformed content blocks" do
    assert Reply.select(
             [%{"type" => "refusal", "refusal" => "Cannot comply"}],
             :end_turn
           ) == {:error, :refusal}

    assert Reply.select(
             [%{"type" => "future_content", "opaque" => %{"nested" => true}}],
             :end_turn
           ) == {:error, {:unexpected_content_block, "future_content"}}

    assert Reply.select([%{"type" => "text", "text" => 123}], :end_turn) ==
             {:error, :invalid_content}

    assert Reply.select(%{"not" => "a list"}, :end_turn) == {:error, :invalid_content}
  end

  test "rejects malformed thinking blocks even when valid text follows" do
    malformed_blocks = [
      %{"type" => "thinking", "thinking" => "missing signature"},
      %{"type" => "thinking", "thinking" => 123, "signature" => "signed"},
      %{"type" => "thinking", "thinking" => "summary", "signature" => nil},
      %{"type" => "redacted_thinking"},
      %{"type" => "redacted_thinking", "data" => 123}
    ]

    Enum.each(malformed_blocks, fn malformed_block ->
      assert Reply.select([malformed_block, text("must not publish")], :end_turn) ==
               {:error, :invalid_content}
    end)
  end

  test "rejects malformed known server-tool calls even when valid text follows" do
    malformed_calls = [
      %{"type" => "server_tool_use", "id" => "call-1", "name" => "web_search"},
      %{"type" => "server_tool_use", "id" => "", "name" => "web_search", "input" => %{}},
      %{"type" => "server_tool_use", "id" => 123, "name" => "web_fetch", "input" => %{}},
      %{"type" => "server_tool_use", "id" => "call-1", "input" => %{}}
    ]

    Enum.each(malformed_calls, fn malformed_call ->
      assert Reply.select([malformed_call, text("must not publish")], :end_turn) ==
               {:error, :invalid_content}
    end)
  end

  test "requires server-tool input while keeping its nested value opaque" do
    content = [
      %{
        "type" => "server_tool_use",
        "id" => "search-opaque-input",
        "name" => "web_search",
        "input" => "opaque-provider-input"
      },
      %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "search-opaque-input",
        "content" => []
      },
      text("publishable")
    ]

    assert Reply.select(content, :end_turn) == {:ok, "publishable"}
  end

  test "rejects malformed known server-tool result payloads" do
    cases = [
      {"web_search", "web_search_tool_result", %{}},
      {"web_search", "web_search_tool_result", %{"content" => "not-a-result"}},
      {"web_fetch", "web_fetch_tool_result", %{}},
      {"web_fetch", "web_fetch_tool_result", %{"content" => nil}}
    ]

    Enum.each(cases, fn {tool_name, result_type, malformed_fields} ->
      content = [
        %{
          "type" => "server_tool_use",
          "id" => "server-call-1",
          "name" => tool_name,
          "input" => %{}
        },
        Map.merge(
          %{"type" => result_type, "tool_use_id" => "server-call-1"},
          malformed_fields
        ),
        text("must not publish")
      ]

      assert Reply.select(content, :end_turn) == {:error, :invalid_content}
    end)
  end

  test "accepts documented success and error server-tool result variants" do
    variants = [
      {"web_search", "web_search_tool_result",
       [
         %{
           "type" => "web_search_result",
           "url" => "https://example.test/result",
           "title" => "Result title",
           "encrypted_content" => "opaque",
           "page_age" => "2 days ago",
           "future_metadata" => %{"preserved" => true}
         }
       ]},
      {"web_search", "web_search_tool_result",
       %{
         "type" => "web_search_tool_result_error",
         "error_code" => "unavailable",
         "future_metadata" => [1, 2, 3]
       }},
      {"web_fetch", "web_fetch_tool_result",
       %{
         "type" => "web_fetch_result",
         "url" => "https://example.test/page",
         "content" => %{"type" => "document", "opaque" => %{"preserved" => true}},
         "retrieved_at" => nil,
         "future_metadata" => "preserved"
       }},
      {"web_fetch", "web_fetch_tool_result",
       %{
         "type" => "web_fetch_tool_result_error",
         "error_code" => "url_not_accessible",
         "future_metadata" => %{"preserved" => true}
       }}
    ]

    Enum.each(variants, fn {tool_name, result_type, result_content} ->
      content = [
        %{
          "type" => "server_tool_use",
          "id" => "server-call-1",
          "name" => tool_name,
          "input" => %{},
          "caller" => %{"type" => "direct", "opaque" => true}
        },
        %{
          "type" => result_type,
          "tool_use_id" => "server-call-1",
          "content" => result_content,
          "caller" => %{"type" => "direct", "opaque" => true}
        },
        text("publishable")
      ]

      assert Reply.select(content, :end_turn) == {:ok, "publishable"}
    end)
  end

  test "rejects unrecognized or malformed server-tool result variants" do
    malformed_variants = [
      {"web_search", "web_search_tool_result", [%{"type" => "future_search_result"}]},
      {"web_search", "web_search_tool_result", [%{"type" => "web_search_result"}]},
      {"web_search", "web_search_tool_result", %{"type" => "web_search_tool_result_error"}},
      {"web_search", "web_search_tool_result",
       %{"type" => "web_search_tool_result_error", "error_code" => 123}},
      {"web_fetch", "web_fetch_tool_result", []},
      {"web_fetch", "web_fetch_tool_result", %{"type" => "future_fetch_result"}},
      {"web_fetch", "web_fetch_tool_result", %{"type" => "web_fetch_result"}},
      {"web_fetch", "web_fetch_tool_result",
       %{
         "type" => "web_fetch_result",
         "url" => "https://example.test",
         "content" => %{"type" => "future_document"},
         "retrieved_at" => nil
       }},
      {"web_fetch", "web_fetch_tool_result", %{"type" => "web_fetch_tool_result_error"}}
    ]

    Enum.each(malformed_variants, fn {tool_name, result_type, result_content} ->
      content = [
        %{
          "type" => "server_tool_use",
          "id" => "server-call-1",
          "name" => tool_name,
          "input" => %{}
        },
        %{
          "type" => result_type,
          "tool_use_id" => "server-call-1",
          "content" => result_content
        },
        text("must not publish")
      ]

      assert Reply.select(content, :end_turn) == {:error, :invalid_content}
    end)
  end

  test "splits over-300-grapheme text at paragraph boundary" do
    part1 = String.duplicate("a", 150)
    part2 = String.duplicate("b", 160)
    text = part1 <> "\n\n" <> part2

    assert String.length(text) == 312
    assert {:ok, split1, split2} = Reply.split_text(text)
    assert String.length(split1) == 150
    assert String.length(split2) == 160
    assert split1 == part1
    assert split2 == part2
  end

  test "splits over-300-grapheme text at sentence boundary when no paragraph break" do
    part1 = String.duplicate("a", 149) <> "."
    part2 = String.duplicate("b", 151)
    text = part1 <> " " <> part2

    assert String.length(text) == 302
    assert {:ok, split1, split2} = Reply.split_text(text)
    assert String.length(split1) == 150
    assert String.length(split2) == 151
    assert split1 == part1
    assert split2 == part2
  end

  test "splits over-300-grapheme text at whitespace when no sentence break near middle" do
    text = String.duplicate("a", 150) <> " " <> String.duplicate("b", 151)

    assert String.length(text) == 302
    assert {:ok, split1, split2} = Reply.split_text(text)
    assert String.length(split1) == 150
    assert String.length(split2) == 151
  end

  test "refuses to split text that cannot be split into two valid parts" do
    single_chunk = String.duplicate("a", 301)
    assert Reply.split_text(single_chunk) == :error
  end

  test "refuses to split text already within limits" do
    within_limits = String.duplicate("a", 300)
    assert Reply.split_text(within_limits) == :error
  end

  test "validates both parts are within grapheme and byte limits" do
    part1 = String.duplicate("👩‍💻", 273)
    part2 = String.duplicate("b", 50)
    text = part1 <> "\n\n" <> part2

    assert String.length(text) > 300
    assert byte_size(part1) > 3_000

    assert Reply.split_text(text) == :error
  end

  defp text(value), do: %{"type" => "text", "text" => value}
end
