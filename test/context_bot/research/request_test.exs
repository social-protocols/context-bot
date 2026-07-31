defmodule ContextBot.Research.RequestTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Request

  @canonical_thread %{
    version: 1,
    text: "CONTEXT_BOT_THREAD_V1\n\n[invocation]\nText:\nPlease add context."
  }

  test "builds the pinned non-streaming Sonnet request with bounded direct web tools" do
    request =
      Request.initial(@canonical_thread, %{
        model_id: "claude-sonnet-5-test-pin",
        max_tokens: 8_192,
        max_web_search_uses: 4,
        max_web_fetch_uses: 3,
        max_web_fetch_content_tokens: 24_000
      })

    assert request["model"] == "claude-sonnet-5-test-pin"
    assert request["max_tokens"] == 8_192
    assert request["stream"] == false
    assert request["cache_control"] == %{"type" => "ephemeral"}
    assert request["thinking"] == %{"type" => "adaptive"}
    assert request["output_config"] == %{"effort" => "high"}
    assert request["tool_choice"] == %{"type" => "auto"}
    assert is_binary(request["system"])

    assert request["messages"] == [
             %{"role" => "user", "content" => @canonical_thread.text}
           ]

    assert request["tools"] == [
             %{
               "type" => "web_search_20260318",
               "name" => "web_search",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "full",
               "max_uses" => 4
             },
             %{
               "type" => "web_fetch_20260318",
               "name" => "web_fetch",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "full",
               "max_uses" => 3,
               "max_content_tokens" => 24_000,
               "use_cache" => false,
               "citations" => %{"enabled" => true}
             }
           ]

    refute Map.has_key?(request, "temperature")
    refute Map.has_key?(request, "top_p")
    refute Map.has_key?(request, "top_k")
    refute Map.has_key?(request["thinking"], "display")
  end

  test "sends one versioned prompt with the complete research and reply safety contract" do
    prompt = Request.initial(@canonical_thread, config())["system"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V1")
    assert prompt =~ "ancestor"
    assert prompt =~ "unstable"
    assert prompt =~ "primary sources"
    assert prompt =~ "facts"
    assert prompt =~ "value judgments"
    assert prompt =~ "uncertainty"
    assert prompt =~ "untrusted"
    assert prompt =~ "prompt injection"
    assert prompt =~ "Return only"
    assert prompt =~ "300 Unicode grapheme clusters"
    assert prompt =~ "audit suffix"
  end

  test "accepts the string-keyed canonical thread representation reloaded from persistence" do
    persisted_thread = %{
      "version" => 1,
      "text" => @canonical_thread.text,
      "current_cid" => "bafy-opaque"
    }

    assert Request.initial(persisted_thread, config())["messages"] == [
             %{"role" => "user", "content" => @canonical_thread.text}
           ]
  end

  test "continues a pause turn by appending every assistant block deeply unchanged" do
    initial = Request.initial(@canonical_thread, config())

    assistant_content = [
      %{
        "type" => "thinking",
        "thinking" => "opaque summary",
        "signature" => "signed-thinking-payload"
      },
      %{
        "type" => "redacted_thinking",
        "data" => "encrypted-provider-payload"
      },
      %{
        "type" => "server_tool_use",
        "id" => "server-call-1",
        "name" => "web_search",
        "input" => %{"query" => "current claim"},
        "caller" => %{"type" => "direct", "opaque" => [1, %{"future" => true}]},
        "future_metadata" => %{"nested" => [nil, false, "unchanged"]}
      },
      %{
        "type" => "future_unknown_block",
        "payload" => %{"bytes" => "opaque", "list" => [1, 2, 3]}
      }
    ]

    continued = Request.continue(initial, assistant_content, initial["max_tokens"])

    assert Map.delete(continued, "messages") == Map.delete(initial, "messages")

    assert continued["messages"] ==
             initial["messages"] ++
               [%{"role" => "assistant", "content" => assistant_content}]

    assert List.last(continued["messages"])["content"] == assistant_content
  end

  test "rejects a continuation token limit that would change the cached request settings" do
    initial = Request.initial(@canonical_thread, config())

    assert_raise ArgumentError, ~r/continuation max_tokens must match/, fn ->
      Request.continue(initial, [%{"type" => "text", "text" => "partial"}], 1_024)
    end
  end

  test "repairs append-only while changing only max_tokens outside the conversation" do
    initial = Request.initial(@canonical_thread, config())

    paused_content = [
      %{
        "type" => "server_tool_use",
        "id" => "server-call-1",
        "name" => "web_fetch",
        "caller" => %{"type" => "direct", "future" => %{"opaque" => true}},
        "input" => %{"url" => "https://example.test/live"}
      }
    ]

    conversation = Request.continue(initial, paused_content, initial["max_tokens"])

    completed_content = [
      %{
        "type" => "thinking",
        "thinking" => "opaque summary",
        "signature" => "signed-completed-thinking"
      },
      %{"type" => "text", "text" => String.duplicate("too long ", 60)},
      %{
        "type" => "future_completed_block",
        "encrypted_content" => "opaque-ciphertext",
        "nested" => [%{"unknown" => [1, 2, 3]}]
      }
    ]

    repaired = Request.repair(conversation, completed_content, 1_024)

    assert repaired["max_tokens"] == 1_024

    assert Map.drop(repaired, ["messages", "max_tokens"]) ==
             Map.drop(conversation, ["messages", "max_tokens"])

    assert Enum.take(repaired["messages"], length(conversation["messages"])) ==
             conversation["messages"]

    assert [assistant_message, repair_message] =
             Enum.drop(repaired["messages"], length(conversation["messages"]))

    assert assistant_message == %{"role" => "assistant", "content" => completed_content}
    assert repair_message["role"] == "user"
    assert String.starts_with?(repair_message["content"], "LENGTH_REPAIR\n")
    assert repair_message["content"] =~ "only the reply text"
    assert repair_message["content"] =~ "at most 300 Unicode grapheme clusters"
    assert repair_message["content"] =~ "Do not perform additional research"
  end

  defp config do
    %{
      model_id: "claude-sonnet-5",
      max_tokens: 8_192,
      max_web_search_uses: 5,
      max_web_fetch_uses: 5,
      max_web_fetch_content_tokens: 50_000
    }
  end
end
