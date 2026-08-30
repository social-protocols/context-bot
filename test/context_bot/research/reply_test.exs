defmodule ContextBot.Research.ReplyTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Reply
  alias ContextBot.Research.ReplyLimits

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
      text("Publish this. "),
      text("Not the tool output.")
    ]

    assert Reply.select(content, :end_turn) == {:ok, "Publish this. Not the tool output."}
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
      text("No primary source found.")
    ]

    assert Reply.select(content, :end_turn) == {:ok, "No primary source found."}
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
      text("Final context only.")
    ]

    context = %{
      stop_reason: "end_turn",
      pending_server_tools: %{"paused-bash-1" => "bash_code_execution"}
    }

    assert Reply.select(completed_content, context) == {:ok, "Final context only."}
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
        text("publishable after cap")
      ]

      assert Reply.select(content, :end_turn) == {:ok, "publishable after cap"}
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

  test "packs part1 to ~275 graphemes at sentence boundary" do
    # Create text with sentence breaks at 200, 270, and 280 graphemes (before trim)
    part_200 = String.duplicate("a", 199) <> "."
    part_270 = String.duplicate("b", 69) <> "."
    part_280 = String.duplicate("c", 9) <> "."
    remainder = String.duplicate("d", 30)
    text = part_200 <> " " <> part_270 <> " " <> part_280 <> " " <> remainder

    assert String.length(text) == 313
    assert {:ok, split1, split2} = Reply.split_text(text)

    # Should split at 271 graphemes (after second sentence, includes trailing space before trim)
    # Split position is at byte after ". " following part_270, then trimmed
    assert String.length(split1) == 271
    assert String.length(split2) == 41
  end

  test "packs part1 to maximum when multiple sentences fit under 275" do
    # Create sentences that cumulatively fit: 100, 201, 276 (after trim)
    s1 = String.duplicate("a", 99) <> "."
    s2 = String.duplicate("b", 99) <> "."
    s3 = String.duplicate("c", 73) <> "."
    s4 = String.duplicate("d", 25)
    text = s1 <> " " <> s2 <> " " <> s3 <> " " <> s4

    assert String.length(text) == 302
    assert {:ok, split1, split2} = Reply.split_text(text)

    # Should split after s2 (201 graphemes after trim, largest ≤ 275)
    # s3 would give 276 which exceeds 275
    assert String.length(split1) == 201
    assert String.length(split2) == 100
  end

  test "splits at whitespace near 275 when no sentence boundary fits" do
    # Create text with only one sentence break at 311 graphemes
    part1 = String.duplicate("a", 280)
    part2 = String.duplicate("b", 30) <> "."
    remainder = String.duplicate("c", 20)
    text = part1 <> " " <> part2 <> " " <> remainder

    assert String.length(text) == 333
    assert {:ok, split1, _split2} = Reply.split_text(text)

    # Should split at whitespace closest to but ≤ 275 when no sentence fits
    split1_len = String.length(split1)
    assert split1_len <= 280 and split1_len >= 270
  end

  test "does not split inv 15 compact at U.S. when a later real sentence exists" do
    # Published Bluesky part 1 from inv 15. The research compact was over 300
    # graphemes; split_text treated the abbreviation period in "U.S. " as a
    # sentence break. Scoring prefers any ≤275 break over a later real ". "
    # between 276 and 300, so part 1 became this mid-thought fragment.
    published_part1 =
      "Google's stated rationale: it has a long-standing policy of mirroring whatever a country's official government geographic database says. Trump's order led the U.S."

    assert String.length(published_part1) == 163

    closing = "The Geographic Names Board then adopted that spelling."
    remainder = "Additional sourced context follows after the real sentence."
    target_left = 280
    filler_len = target_left - String.length(published_part1) - 1 - String.length(closing)

    text =
      published_part1 <> " " <> String.duplicate("a", filler_len) <> closing <> " " <> remainder

    first_sentence =
      "Google's stated rationale: it has a long-standing policy of mirroring whatever a country's official government geographic database says."

    assert String.length(text) > 300

    assert String.length(published_part1 <> " " <> String.duplicate("a", filler_len) <> closing) ==
             target_left

    assert String.contains?(text, "U.S. ")
    assert String.contains?(text, closing <> " ")

    assert {:ok, split1, split2} = Reply.split_text(text)
    refute split1 == published_part1
    refute String.ends_with?(split1, "led the U.S.")
    # "says." is the longest real sentence ≤275; the later closing sits at 280.
    assert split1 == first_sentence
    assert String.starts_with?(split2, "Trump's order led the U.S.")
  end

  test "does not treat listed abbreviations as sentence breaks" do
    for abbreviation <- ["U.S.", "U.K.", "e.g.", "i.e.", "Mr.", "Ms.", "Dr."] do
      prefix = "Context includes #{abbreviation}"
      closing = "This later clause is the real sentence."
      remainder = String.duplicate("z", 40)
      target_left = 280
      filler_len = target_left - String.length(prefix) - 1 - String.length(closing)
      text = prefix <> " " <> String.duplicate("a", filler_len) <> closing <> " " <> remainder

      assert String.length(text) > 300
      assert {:ok, split1, split2} = Reply.split_text(text)
      refute String.ends_with?(split1, abbreviation)
      assert String.ends_with?(split1, closing)
      assert split2 == remainder
    end
  end

  test "falls back to whitespace when the only period-space is an abbreviation" do
    prefix = "Trump's order led the U.S."
    # A 27-grapheme whitespace after the abbreviation would leave part2 over cap.
    # Place a later whitespace at 275 so the fallback can pack a valid part1.
    a_count = 275 - String.length(prefix) - 2
    text = prefix <> " " <> String.duplicate("a", a_count) <> " " <> String.duplicate("b", 80)

    assert String.length(text) > 300
    assert {:ok, split1, split2} = Reply.split_text(text)
    refute String.ends_with?(split1, "led the U.S.")
    assert String.contains?(split1, "U.S.")
    assert String.length(split1) == 274
    assert String.starts_with?(split2, "b")
  end

  defp text(value), do: %{"type" => "text", "text" => value}
end
