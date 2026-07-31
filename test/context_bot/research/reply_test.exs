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
            "encrypted_content" => "opaque-search-result"
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
        "content" => %{"type" => "web_fetch_result", "encrypted_content" => "opaque-fetch"}
      },
      %{"type" => "text", "text" => "second."}
    ]

    assert Reply.select(content, :end_turn) == {:ok, "First second."}
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

  defp text(value), do: %{"type" => "text", "text" => value}
end
