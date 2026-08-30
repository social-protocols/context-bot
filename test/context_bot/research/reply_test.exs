defmodule ContextBot.Research.ReplyTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.Post
  alias ContextBot.Research.Reply
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Research.StructuredFixtures
  alias Unicode.String.Segment

  test "accepts ordered model text at exactly 300 graphemes and 3,000 bytes" do
    reply =
      String.duplicate("👩‍💻", 268) <>
        String.duplicate("e\u0301", 8) <>
        String.duplicate("é", 4) <>
        String.duplicate("a", 20)

    assert String.length(reply) == 300
    assert byte_size(reply) == 3_000

    encoded = StructuredFixtures.structured_json(reply)
    {first, second} = String.split_at(encoded, div(String.length(encoded), 2))

    content = [
      %{"type" => "text", "text" => first},
      %{"type" => "text", "text" => second}
    ]

    assert Reply.select(content, "end_turn") == StructuredFixtures.selected(reply)
  end

  test "ignores opaque thinking and completed expected server-tool blocks" do
    content = [
      %{"type" => "thinking", "thinking" => "opaque", "signature" => "signed"},
      structured_text("First second."),
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
      }
    ]

    assert Reply.select(content, :end_turn) == StructuredFixtures.selected("First second.")
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
      structured_text("First second.")
    ]

    assert Reply.select(content, :end_turn) == StructuredFixtures.selected("First second.")
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
      structured_text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-code-1" => "code_execution"}
    }

    assert Reply.select(completed_content, context) ==
             StructuredFixtures.selected("Final context only.")
  end

  test "accepts paired bash and text-editor code execution while selecting only model text" do
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
          "encrypted_stdout" => "opaque"
        }
      },
      %{
        "type" => "server_tool_use",
        "id" => "bash-1",
        "name" => "bash_code_execution",
        "input" => %{"command" => "sleep 20 && echo done"}
      },
      %{
        "type" => "bash_code_execution_tool_result",
        "tool_use_id" => "bash-1",
        "content" => %{
          "type" => "bash_code_execution_result",
          "stdout" => "done\n",
          "stderr" => "",
          "return_code" => 0,
          "content" => []
        }
      },
      %{
        "type" => "server_tool_use",
        "id" => "editor-1",
        "name" => "text_editor_code_execution",
        "input" => %{"command" => "view", "path" => "/tmp/notes.md"}
      },
      %{
        "type" => "text_editor_code_execution_tool_result",
        "tool_use_id" => "editor-1",
        "content" => %{
          "type" => "text_editor_code_execution_view_result",
          "file_type" => "text",
          "content" => "opaque file body"
        }
      },
      %{
        "type" => "server_tool_use",
        "id" => "code-2",
        "name" => "code_execution",
        "input" => %{"code" => "more opaque"}
      },
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "code-2",
        "content" => %{"type" => "code_execution_result", "content" => []}
      },
      structured_text("Publish this. Not the tool output.")
    ]

    assert Reply.select(content, :end_turn) ==
             StructuredFixtures.selected("Publish this. Not the tool output.")
  end

  test "fails closed when bash_code_execution returns a non-zero return_code" do
    content = [
      %{
        "type" => "server_tool_use",
        "id" => "bash-1",
        "name" => "bash_code_execution",
        "input" => %{"command" => "web_search('Lake America')"}
      },
      %{
        "type" => "bash_code_execution_tool_result",
        "tool_use_id" => "bash-1",
        "content" => %{
          "type" => "bash_code_execution_result",
          "stdout" => "",
          "stderr" => "encrypted-unreadable",
          "return_code" => 1,
          "content" => []
        }
      },
      text("must not publish")
    ]

    assert Reply.select(content, :end_turn) == {:error, :code_execution_failed}
  end

  test "fails closed when encrypted code_execution stdout has a non-zero return_code" do
    content = [
      %{
        "type" => "server_tool_use",
        "id" => "code-1",
        "name" => "code_execution",
        "input" => %{"code" => "web_search('Lake Ontario Lake America')"}
      },
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "code-1",
        "content" => %{
          "type" => "encrypted_code_execution_result",
          "encrypted_stdout" => "opaque",
          "stderr" => "",
          "return_code" => 1,
          "content" => []
        }
      },
      text("must not publish")
    ]

    assert Reply.select(content, :end_turn) == {:error, :code_execution_failed}
  end

  test "fails closed on documented code-execution tool-result errors and timeouts" do
    variants = [
      {"code_execution", "code_execution_tool_result",
       %{
         "type" => "code_execution_tool_result_error",
         "error_code" => "unavailable"
       }},
      {"bash_code_execution", "bash_code_execution_tool_result",
       %{
         "type" => "bash_code_execution_tool_result_error",
         "error_code" => "execution_time_exceeded"
       }},
      {"code_execution", "code_execution_tool_result",
       %{
         "type" => "code_execution_result",
         "stdout" => "detection_timeout",
         "stderr" => "",
         "return_code" => 1,
         "content" => []
       }}
    ]

    Enum.each(variants, fn {tool_name, result_type, result_content} ->
      content = [
        %{
          "type" => "server_tool_use",
          "id" => "exec-1",
          "name" => tool_name,
          "input" => %{}
        },
        %{
          "type" => result_type,
          "tool_use_id" => "exec-1",
          "content" => result_content
        },
        text("must not publish")
      ]

      assert Reply.select(content, :end_turn) == {:error, :code_execution_failed}
    end)
  end

  test "still selects a reply after successful code_execution with a negative research finding" do
    content = [
      %{
        "type" => "server_tool_use",
        "id" => "code-1",
        "name" => "code_execution",
        "input" => %{"code" => "print('no primary source found')"}
      },
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "code-1",
        "content" => %{
          "type" => "code_execution_result",
          "stdout" => "no primary source found\n",
          "stderr" => "",
          "return_code" => 0,
          "content" => []
        }
      },
      structured_text("No primary source found.")
    ]

    assert Reply.select(content, :end_turn) ==
             StructuredFixtures.selected("No primary source found.")
  end

  test "fails closed on unexpected_tool_use even when compact reply text follows" do
    content = [
      %{
        "type" => "server_tool_use",
        "id" => "unexpected-1",
        "name" => "future_server_tool",
        "input" => %{}
      },
      text("must not publish")
    ]

    assert Reply.select(content, :end_turn) == {:error, :unexpected_tool_use}
  end

  test "fails closed on malformed, duplicate, mismatched, and orphaned bash code execution" do
    call = %{
      "type" => "server_tool_use",
      "id" => "bash-1",
      "name" => "bash_code_execution",
      "input" => %{"command" => "echo done"}
    }

    result = %{
      "type" => "bash_code_execution_tool_result",
      "tool_use_id" => "bash-1",
      "content" => %{"type" => "bash_code_execution_result", "stdout" => "done\n"}
    }

    invalid_content = [
      [Map.delete(call, "id"), result, text("must not publish")],
      [Map.put(call, "id", ""), result, text("must not publish")],
      [Map.put(call, "input", "not-a-map"), result, text("must not publish")],
      [call, Map.delete(result, "content"), text("must not publish")],
      [call, Map.put(result, "content", []), text("must not publish")],
      [call, Map.put(result, "tool_use_id", "other"), text("must not publish")],
      [call, call, result, text("must not publish")],
      [result, text("must not publish")]
    ]

    Enum.each(invalid_content, fn content ->
      assert {:error, _reason} = Reply.select(content, :end_turn)
    end)
  end

  test "completes bash code execution started in a prior pause" do
    completed_content = [
      %{
        "type" => "bash_code_execution_tool_result",
        "tool_use_id" => "paused-bash-1",
        "content" => %{"type" => "bash_code_execution_result", "stdout" => "done\n"}
      },
      structured_text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-bash-1" => "bash_code_execution"}
    }

    assert Reply.select(completed_content, context) ==
             StructuredFixtures.selected("Final context only.")
  end

  test "fails closed when a paused bash_code_execution completes with return_code 1" do
    completed_content = [
      %{
        "type" => "bash_code_execution_tool_result",
        "tool_use_id" => "paused-bash-1",
        "content" => %{
          "type" => "bash_code_execution_result",
          "stdout" => "",
          "stderr" => "encrypted-unreadable",
          "return_code" => 1
        }
      },
      text("must not publish")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-bash-1" => "bash_code_execution"}
    }

    assert Reply.select(completed_content, context) == {:error, :code_execution_failed}
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
      structured_text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-fetch-1" => "web_fetch"}
    }

    assert Reply.select(completed_content, context) ==
             StructuredFixtures.selected("Final context only.")
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

    assert Reply.select([structured_text(at_276)], "end_turn") ==
             StructuredFixtures.selected(at_276)

    assert Reply.select([structured_text(at_280)], "end_turn") ==
             StructuredFixtures.selected(at_280)

    assert Reply.select([structured_text(at_300)], "end_turn") ==
             StructuredFixtures.selected(at_300)
  end

  test "classifies over-limit normal completions as repairable without truncating" do
    over_graphemes = String.duplicate("a", 301)
    over_bytes = String.duplicate("👩‍💻", 272) <> String.duplicate("a", 9)
    over_both = String.duplicate("👩‍💻", 301)

    assert String.length(over_graphemes) == 301
    assert byte_size(over_bytes) == 3_001
    assert String.length(over_bytes) == 281

    assert Reply.select([structured_text(over_graphemes)], "end_turn") ==
             {:repairable, over_graphemes, [:too_many_graphemes]}

    assert Reply.select([structured_text(over_bytes)], "end_turn") ==
             {:repairable, over_bytes, [:too_many_bytes]}

    assert Reply.select([structured_text(over_both)], "end_turn") ==
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
      structured_text("publishable")
    ]

    assert Reply.select(content, :end_turn) == StructuredFixtures.selected("publishable")
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
        structured_text("publishable")
      ]

      assert Reply.select(content, :end_turn) == StructuredFixtures.selected("publishable")
    end)
  end

  test "treats max_uses_exceeded web-tool errors as completed turns" do
    for {tool_name, result_type} <- [
          {"web_search", "web_search_tool_result"},
          {"web_fetch", "web_fetch_tool_result"}
        ] do
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
          "content" => %{
            "type" => "#{tool_name}_tool_result_error",
            "error_code" => "max_uses_exceeded"
          }
        },
        structured_text("publishable after cap")
      ]

      assert Reply.select(content, :end_turn) ==
               StructuredFixtures.selected("publishable after cap")
    end
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

  test "fits_one_post?/1 accepts 300 graphemes and rejects 301" do
    assert ReplyLimits.fits_one_post?(String.duplicate("a", 300))
    refute ReplyLimits.fits_one_post?(String.duplicate("a", 301))
  end

  test "validates both parts are within grapheme and byte limits" do
    part1 = String.duplicate("👩‍💻", 273)
    part2 = String.duplicate("b", 50)
    text = part1 <> "\n\n" <> part2

    assert String.length(text) > 300
    assert byte_size(part1) > 3_000

    assert Reply.split_text(text) == :error
  end

  test "packs part1 to the hard cap at a later sentence, not the 275 prompt target" do
    part_200 = String.duplicate("a", 199) <> "."
    part_270 = String.duplicate("b", 69) <> "."
    part_280 = String.duplicate("c", 9) <> "."
    remainder = String.duplicate("d", 30)
    text = part_200 <> " " <> part_270 <> " " <> part_280 <> " " <> remainder

    assert String.length(text) == 313
    assert {:ok, split1, split2} = Reply.split_text(text)

    # Third sentence ends at 282, still under the 300 hard cap. The 275 prompt
    # target is for the model, not for packing a split.
    assert String.length(split1) == 282
    assert String.length(split2) == 30
    assert String.ends_with?(split1, part_280)
  end

  test "packs a 276-grapheme sentence that the old 275 target would have skipped" do
    s1 = String.duplicate("a", 99) <> "."
    s2 = String.duplicate("b", 99) <> "."
    s3 = String.duplicate("c", 73) <> "."
    s4 = String.duplicate("d", 25)
    text = s1 <> " " <> s2 <> " " <> s3 <> " " <> s4

    assert String.length(text) == 302
    assert {:ok, split1, split2} = Reply.split_text(text)

    # s1+s2 is 201; s3 brings part 1 to 276, which is valid under the hard cap.
    assert String.length(split1) == 276
    assert String.length(split2) == 25
    assert String.ends_with?(split1, s3)
  end

  test "splits at the last whitespace that still fits the hard cap" do
    part1 = String.duplicate("a", 280)
    part2 = String.duplicate("b", 30) <> "."
    remainder = String.duplicate("c", 20)
    text = part1 <> " " <> part2 <> " " <> remainder

    assert String.length(text) == 333
    assert {:ok, split1, split2} = Reply.split_text(text)
    assert String.length(split1) == 280
    assert split1 == part1
    assert String.starts_with?(split2, part2)
  end

  test "English CLDR sentence suppressions include U.S." do
    suppressions = Segment.suppressions!("en", :sentence_break)
    assert "U.S." in suppressions
  end

  test "does not split inv 15 compact at U.S. when packing to the hard cap" do
    # Published Bluesky part 1 from inv 15. The research compact was over 300
    # graphemes; raw ". " matching treated "U.S. " as a sentence break.
    # English CLDR suppressions include U.S., so UAX #29 keeps "U.S. Board"
    # in the same sentence. Packing may take that whole sentence; it must not
    # cut after the abbreviation.
    published_part1 =
      "Google's stated rationale: it has a long-standing policy of mirroring whatever a country's official government geographic database says. Trump's order led the U.S."

    assert String.length(published_part1) == 163

    first_sentence =
      "Google's stated rationale: it has a long-standing policy of mirroring whatever a country's official government geographic database says."

    us_through_board = "Trump's order led the U.S. Board then adopted that spelling."
    remainder = String.duplicate("z", 120)
    compact_prefix = first_sentence <> " " <> us_through_board
    text = compact_prefix <> " " <> remainder

    assert String.length(text) > 300
    assert String.contains?(text, "says. Trump's")
    assert String.contains?(text, "U.S. Board")

    assert Unicode.String.split(compact_prefix, break: :sentence, locale: "en", trim: true) == [
             first_sentence <> " ",
             us_through_board
           ]

    assert {:ok, split1, split2} = Reply.split_text(text)
    refute split1 == published_part1
    refute String.ends_with?(split1, "led the U.S.")
    assert String.contains?(split1, "U.S. Board")
    assert split1 == compact_prefix
    assert split2 == remainder
  end

  test "prefers a later sentence split that leaves room on part 2 for the link suffix" do
    early = String.duplicate("a", 249) <> "."
    later = String.duplicate("b", 29) <> "."
    rest = String.duplicate("c", 259)
    text = early <> " " <> later <> " " <> rest

    assert String.length(text) > 300
    assert {:ok, split1, split2} = Reply.split_text(text)
    refute String.ends_with?(split1, String.duplicate("a", 10) <> ".")
    assert String.ends_with?(split1, later)
    assert ReplyLimits.fits_one_post?(split2 <> Post.link_suffix())
  end

  test "falls back to whitespace when the only period-space is an abbreviation" do
    prefix = "Trump's order led the U.S."
    # A 27-grapheme whitespace after the abbreviation would leave part2 over cap.
    # Place a later whitespace at the hard cap so packing fills part 1.
    a_count = ReplyLimits.hard_max_graphemes() - String.length(prefix) - 2
    text = prefix <> " " <> String.duplicate("a", a_count) <> " " <> String.duplicate("b", 80)

    assert String.length(text) > 300
    assert {:ok, split1, split2} = Reply.split_text(text)
    refute String.ends_with?(split1, "led the U.S.")
    assert String.contains?(split1, "U.S.")
    assert String.length(split1) == 299
    assert String.starts_with?(split2, "b")
  end

  test "packs the East Potomac compact to the last whitespace before 300" do
    compact =
      "Disputed, not settled. Interior/NPS says it's \"routine maintenance\" removing hazard, invasive, and dying trees — unrelated to the golf redesign. But it won't confirm/deny cherry trees cut were healthy, timing lines up with Trump's Sept 1 construction target, a $349k contract runs into October, and a lawsuit's court-notification terms reportedly haven't been followed. No proof either way yet."

    first_two =
      "Disputed, not settled. Interior/NPS says it's \"routine maintenance\" removing hazard, invasive, and dying trees — unrelated to the golf redesign."

    expected_part1 =
      "Disputed, not settled. Interior/NPS says it's \"routine maintenance\" removing hazard, invasive, and dying trees — unrelated to the golf redesign. But it won't confirm/deny cherry trees cut were healthy, timing lines up with Trump's Sept 1 construction target, a $349k contract runs into October, and a"

    expected_part2 =
      "lawsuit's court-notification terms reportedly haven't been followed. No proof either way yet."

    assert String.length(compact) == 394
    assert String.length(first_two) == 144
    assert {:ok, split1, split2} = Reply.split_text(compact)
    refute split1 == first_two
    assert split1 == expected_part1
    assert split2 == expected_part2
    assert String.length(split1) == 300
    assert String.length(split2) == 93
    assert ReplyLimits.fits_one_post?(split1)
    assert ReplyLimits.fits_one_post?(split2)
    assert ReplyLimits.fits_one_post?(split2 <> Post.link_suffix())
  end

  test "a word-boundary pack near 290 beats a sentence split near 160" do
    s1 = String.duplicate("a", 79) <> "."
    s2 = String.duplicate("b", 79) <> "."
    words = Enum.map_join(1..14, " ", fn _ -> String.duplicate("c", 9) end)
    overflow = String.duplicate("d", 40)
    text = s1 <> " " <> s2 <> " " <> words <> " " <> overflow

    assert String.length(s1 <> " " <> s2) == 161
    assert String.length(text) > 300
    assert {:ok, split1, split2} = Reply.split_text(text)
    refute String.length(split1) == 161
    assert String.length(split1) == 291
    assert String.ends_with?(split1, String.duplicate("c", 9))
    assert String.starts_with?(split2, String.duplicate("c", 9) <> " " <> overflow)
  end

  test "prefers a paragraph pack over an earlier sentence of the same leftover hole" do
    opening = "Short sentence. "
    rest_of_paragraph = String.duplicate("x", 270)
    paragraph = opening <> rest_of_paragraph
    text = paragraph <> "\n\n" <> String.duplicate("y", 40)

    assert String.length(String.trim(opening)) == 15
    assert String.length(paragraph) == 286
    assert {:ok, split1, split2} = Reply.split_text(text)
    refute split1 == String.trim(opening)
    assert split1 == paragraph
    assert String.length(split1) == 286
    assert String.starts_with?(split2, "y")
  end

  test "at equal part-1 length prefers a sentence end over a mid-sentence word" do
    s1 = String.duplicate("a", 139) <> "."
    s2 = String.duplicate("b", 139) <> "."
    overflow = String.duplicate("c", 50)
    text = s1 <> " " <> s2 <> " " <> overflow

    assert {:ok, split1, split2} = Reply.split_text(text)
    assert String.length(split1) == 281
    assert String.ends_with?(split1, ".")
    assert split2 == overflow
  end

  defp structured_text(compact, opts \\ []) do
    text(StructuredFixtures.structured_json(compact, opts))
  end

  defp text(value), do: %{"type" => "text", "text" => value}
end
