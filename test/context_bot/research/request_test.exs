defmodule ContextBot.Research.RequestTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Request
  alias ContextBot.StandardSite.TitlePrompt

  @canonical_thread %{
    version: 1,
    text: "CONTEXT_BOT_THREAD_V1\n\n[invocation]\nText:\nPlease add context."
  }

  @canonical_thread_v2 %{
    version: 2,
    text:
      "CONTEXT_BOT_THREAD_V2\n\n[target]\nText:\nAurora\nImages:\n- [image 1] Alt text: Pale lights",
    media: [
      %{
        "type" => "image",
        "index" => 1,
        "post_uri" => "at://did:plc:author/app.bsky.feed.post/aurora",
        "url" => "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg",
        "alt" => "Pale lights"
      }
    ]
  }

  test "builds the pinned non-streaming Sonnet request with native-only web tools" do
    request =
      Request.initial(@canonical_thread, %{
        model_id: "claude-sonnet-5-test-pin",
        effort: :medium,
        max_tokens: 8_192,
        max_web_search_uses: 4,
        max_web_fetch_uses: 3,
        max_web_fetch_content_tokens: 24_000,
        web_search_tool_type: "web_search_20270809",
        web_fetch_tool_type: "web_fetch_20270809"
      })

    assert request["model"] == "claude-sonnet-5-test-pin"
    assert request["max_tokens"] == 8_192
    assert request["stream"] == false
    assert request["cache_control"] == %{"type" => "ephemeral"}
    assert request["thinking"] == %{"type" => "adaptive"}
    assert_output_config(request, "medium")
    assert request["tool_choice"] == %{"type" => "auto"}
    assert is_binary(request["system"])

    assert request["messages"] == [
             %{"role" => "user", "content" => @canonical_thread.text}
           ]

    assert request["tools"] == [
             %{
               "type" => "web_search_20270809",
               "name" => "web_search",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "excluded",
               "max_uses" => 4
             },
             %{
               "type" => "web_fetch_20270809",
               "name" => "web_fetch",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "excluded",
               "max_uses" => 3,
               "max_content_tokens" => 24_000,
               # Structured JSON + web_fetch citations.enabled=true 400s.
               "citations" => %{"enabled" => false}
             }
           ]

    refute Map.has_key?(request, "temperature")
    refute Map.has_key?(request, "top_p")
    refute Map.has_key?(request, "top_k")
    refute Map.has_key?(request["thinking"], "display")
    refute Map.has_key?(Enum.at(request["tools"], 1), "use_cache")
  end

  test "sends one versioned prompt with the complete research and reply safety contract" do
    prompt = Request.initial(@canonical_thread, config())["system"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V9")
    assert prompt =~ "ancestor"
    assert prompt =~ "unstable"
    assert prompt =~ "primary sources"
    assert prompt =~ "native web_search"
    assert prompt =~ "web_fetch"
    assert prompt =~ "code execution"
    assert prompt =~ "smallest amount of web research"
    assert prompt =~ "facts"
    assert prompt =~ "value judgments"
    assert prompt =~ "uncertainty"
    assert prompt =~ "untrusted"
    assert prompt =~ "prompt injection"
    assert prompt =~ "275 Unicode grapheme"
    refute prompt =~ "at most 300 Unicode grapheme clusters"
    refute prompt =~ "---COMPACT_REPLY---"
    assert prompt =~ "disposition"
    assert prompt =~ "no_reply"
    assert prompt =~ "getcontext.bot is great"
    assert prompt =~ "you should ask getcontext.bot"
    assert prompt =~ "When in doubt, reply"
    assert prompt =~ "title"
    assert prompt =~ "compact_reply"
    assert prompt =~ "full_response"
    assert prompt =~ "What Is That Bird?"
    assert prompt =~ "one Bluesky post"
    assert prompt =~ "images and their alt text"
    assert prompt =~ "directly"
    assert prompt =~ "observe in an image"
    assert prompt =~ "provenance"
    assert prompt =~ "AI-generated"
    assert prompt =~ "visual"
    assert prompt =~ "appearance alone"
  end

  test "places ordered version 2 URL images before the canonical transcript" do
    request = Request.initial(@canonical_thread_v2, config())

    assert request["messages"] == [
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "url",
                     "url" =>
                       "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
                   }
                 },
                 %{"type" => "text", "text" => @canonical_thread_v2.text}
               ]
             }
           ]
  end

  test "uses a content list for text-only version 2 while preserving version 1 strings" do
    text_only = %{version: 2, text: "CONTEXT_BOT_THREAD_V2\n\nText only", media: []}

    assert Request.initial(text_only, config())["messages"] == [
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => text_only.text}]
             }
           ]

    assert Request.initial(@canonical_thread, config())["messages"] == [
             %{"role" => "user", "content" => @canonical_thread.text}
           ]
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

  test "exposes a stable hashed identity for the versioned system prompt" do
    prompt = Request.system_prompt()

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V9")
    assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V9"
    assert Request.system_prompt_semantic_version() == "9.0.0"

    assert Request.system_prompt_sha256() ==
             :sha256 |> :crypto.hash(prompt) |> Base.encode16(case: :lower)

    assert Request.system_prompt_rkey() ==
             "prompt-context-bot-system-v9-#{String.slice(Request.system_prompt_sha256(), 0, 16)}"
  end

  test "projects allowlisted Messages parameters and the first user message" do
    request = Request.initial(@canonical_thread, config())

    projection =
      Request.public_projection(request, %{
        anthropic_api_version: "2023-06-01",
        research_max_tokens: 4_096
      })

    assert projection.prompt.id == "CONTEXT_BOT_SYSTEM_V9"
    assert projection.prompt.semantic_version == "9.0.0"
    assert projection.prompt.sha256 == Request.system_prompt_sha256()
    assert projection.parameters["anthropic-version"] == "2023-06-01"
    assert projection.parameters["model"] == "claude-sonnet-5"
    assert projection.parameters["max_tokens"] == 4_096
    assert projection.parameters["effort"] == "medium"
    assert projection.parameters["output_format"] == "json_schema"
    assert projection.parameters["thinking"] == "adaptive"
    assert projection.parameters["tool_choice"] == "auto"
    assert projection.parameters["cache_control"] == "ephemeral"
    assert projection.parameters["stream"] == false
    assert projection.parameters["continuation"] == false
    assert projection.parameters["length_repair"] == false

    assert projection.parameters["tools"] == [
             %{
               "type" => "web_search_20260318",
               "name" => "web_search",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "excluded",
               "max_uses" => 2
             },
             %{
               "type" => "web_fetch_20260318",
               "name" => "web_fetch",
               "allowed_callers" => ["direct"],
               "response_inclusion" => "excluded",
               "max_uses" => 2,
               "max_content_tokens" => 10_000,
               "citations" => false
             }
           ]

    assert projection.user_message == %{"text" => @canonical_thread.text, "images" => []}
    assert projection.continuation == false
    assert projection.length_repair == false
    refute Map.has_key?(projection.parameters, "x-api-key")
    refute inspect(projection) =~ "sk-ant"
  end

  test "projects version 2 image URL blocks and omits non-CDN sources" do
    request =
      Request.initial(@canonical_thread_v2, config())
      |> put_in(
        ["messages", Access.at(0), "content"],
        [
          %{
            "type" => "image",
            "source" => %{
              "type" => "url",
              "url" =>
                "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
            }
          },
          %{
            "type" => "image",
            "source" => %{"type" => "url", "url" => "https://evil.example/secret?token=abc"}
          },
          %{"type" => "text", "text" => @canonical_thread_v2.text}
        ]
      )

    projection =
      Request.public_projection(request, %{anthropic_api_version: "2023-06-01"})

    assert projection.user_message["text"] == @canonical_thread_v2.text

    assert projection.user_message["images"] == [
             %{
               "url" =>
                 "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
             }
           ]

    refute inspect(projection) =~ "evil.example"
    refute inspect(projection) =~ "token=abc"
  end

  test "flags continuation and length-repair without copying assistant thinking" do
    initial = Request.initial(@canonical_thread, config())

    continued =
      Request.continue(
        initial,
        [
          %{
            "type" => "thinking",
            "thinking" => "hidden chain of thought",
            "signature" => "signed-thinking-payload"
          }
        ],
        initial["max_tokens"]
      )

    continued_projection =
      Request.public_projection(continued, %{
        anthropic_api_version: "2023-06-01",
        research_max_tokens: 4_096
      })

    assert continued_projection.continuation == true
    assert continued_projection.length_repair == false
    assert continued_projection.parameters["continuation"] == true
    refute inspect(continued_projection) =~ "hidden chain of thought"
    refute inspect(continued_projection) =~ "signed-thinking-payload"
  end

  test "projects a historically stored length-repair conversation without copying the prompt" do
    request =
      @canonical_thread
      |> then(&Request.initial(&1, config()))
      |> Map.put("max_tokens", 1_024)
      |> Map.update!("messages", fn messages ->
        messages ++
          [
            %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "too long"}]},
            %{"role" => "user", "content" => "LENGTH_REPAIR\nrewrite"}
          ]
      end)

    projection =
      Request.public_projection(request, %{
        anthropic_api_version: "2023-06-01",
        research_max_tokens: 4_096
      })

    assert projection.continuation == false
    assert projection.length_repair == true
    assert projection.parameters["max_tokens"] == 4_096
    assert projection.parameters["research_max_tokens"] == 4_096
    assert projection.parameters["length_repair_max_tokens"] == 1_024
    refute inspect(projection) =~ "LENGTH_REPAIR\n"
  end

  test "drops injected secrets from the public projection" do
    request =
      config()
      |> then(&Request.initial(@canonical_thread, &1))
      |> Map.merge(%{
        "x-api-key" => "sk-ant-secret",
        "authorization" => "Bearer secret-token",
        "cookie" => "session=secret"
      })

    projection =
      Request.public_projection(request, %{anthropic_api_version: "2023-06-01"})

    refute inspect(projection) =~ "sk-ant-secret"
    refute inspect(projection) =~ "Bearer secret-token"
    refute inspect(projection) =~ "session=secret"
  end

  test "V9 prompt and schema require answering the invoker's questions first" do
    prompt = Request.system_prompt()
    normalized = String.replace(prompt, ~r/\s+/, " ")
    schema = Request.output_schema()
    compact = schema["properties"]["compact_reply"]["description"]
    full = schema["properties"]["full_response"]["description"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V9")
    assert normalized =~ "invoking mention"
    assert normalized =~ "last post in the canonical thread"
    assert normalized =~ "every distinct question"
    assert normalized =~ "Open by directly answering each asked question"
    assert normalized =~ "yes / no / unknown / contested"
    assert normalized =~ "Do not lead with background"
    assert normalized =~ "news lede"
    assert normalized =~ "both-sides"
    assert normalized =~ "value-laden label"
    assert normalized =~ "voter suppression"
    assert normalized =~ "Never silently drop a later question"
    assert normalized =~ "bottom-line paragraph"
    refute normalized =~ "Capture the core finding concisely"

    assert compact =~ "Open by directly answering each asked question"
    assert compact =~ "yes / no / unknown / contested"
    assert compact =~ "Never silently drop a later question"
    refute compact =~ "Capture the core finding concisely"

    assert full =~ "bottom-line paragraph"
    assert full =~ "same question"
    refute full =~ "Capture the core finding concisely"
  end

  test "V9 prompt and schema require markdown https source URLs in full_response" do
    prompt = Request.system_prompt()
    normalized = String.replace(prompt, ~r/\s+/, " ")
    schema = Request.output_schema()
    compact = schema["properties"]["compact_reply"]["description"]
    full = schema["properties"]["full_response"]["description"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V9")
    assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V9"
    assert Request.system_prompt_semantic_version() == "9.0.0"

    assert normalized =~ "Sources"
    assert normalized =~ "[label](https://"
    assert normalized =~ "https://"
    assert normalized =~ "outlet name alone"
    assert normalized =~ "Do not invent URLs"
    assert normalized =~ "not fetched"
    assert normalized =~ "web_search"
    assert normalized =~ "web_fetch"

    assert full =~ "Sources"
    assert full =~ "[label](https://"
    assert full =~ "https://"
    assert full =~ "outlet name alone"
    assert full =~ "Do not invent URLs"
    assert full =~ "not fetched"

    assert compact =~ "plain text"
    assert compact =~ "without markdown"
    refute compact =~ "[label](https://"
    refute compact =~ "Sources section"
  end

  test "builds a title-only rewrite request with no tools and the leftover repair token cap" do
    request =
      Request.title_rewrite(%{
        model_id: "claude-haiku-4-5",
        max_tokens: 1_024,
        invocation_text: "@getcontext.bot what bird is that?",
        compact_reply: "A Himalayan Monal.",
        full_response: "Thorough markdown writeup."
      })

    assert request["model"] == "claude-haiku-4-5"
    assert request["max_tokens"] == 1_024
    assert request["stream"] == false
    refute Map.has_key?(request, "tools")
    refute Map.has_key?(request, "tool_choice")
    assert request["system"] == TitlePrompt.prompt()
    assert request["output_config"]["format"]["type"] == "json_schema"
    assert request["output_config"]["format"]["schema"] == Request.title_schema()
    assert request["output_config"]["format"]["schema"]["required"] == ["title"]

    refute Map.has_key?(
             request["output_config"]["format"]["schema"]["properties"],
             "compact_reply"
           )

    [user] = request["messages"]
    assert user["role"] == "user"
    assert user["content"] =~ "@getcontext.bot what bird is that?"
    assert user["content"] =~ "A Himalayan Monal."
    assert user["content"] =~ "Thorough markdown writeup."
    refute user["content"] =~ "LENGTH_REPAIR"
  end

  test "sends json_schema format beside effort and omits unsupported length keywords" do
    request = Request.initial(@canonical_thread, config())
    schema = Request.output_schema()
    encoded = Jason.encode!(request)

    assert_output_config(request, "medium")
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false
    assert schema["required"] == ["disposition", "title", "compact_reply", "full_response"]
    assert schema["properties"]["disposition"]["enum"] == ["reply", "no_reply"]
    assert schema["properties"]["disposition"]["description"] =~ "no_reply"
    assert schema["properties"]["disposition"]["description"] =~ "ambiguous"
    assert schema["properties"]["title"]["description"] =~ "What Is That Bird?"
    assert schema["properties"]["compact_reply"]["description"] =~ "275"

    assert schema["properties"]["compact_reply"]["description"] =~
             "Write Unicode characters directly"

    refute encoded =~ "maxLength"
    refute encoded =~ "minLength"
    refute encoded =~ "structured-outputs"
  end

  defp assert_output_config(request, effort) do
    assert request["output_config"]["effort"] == effort
    assert request["output_config"]["format"]["type"] == "json_schema"
    assert request["output_config"]["format"]["schema"] == Request.output_schema()
  end

  defp config do
    %{
      model_id: "claude-sonnet-5",
      effort: :medium,
      max_tokens: 4_096,
      max_web_search_uses: 2,
      max_web_fetch_uses: 2,
      max_web_fetch_content_tokens: 10_000,
      web_search_tool_type: "web_search_20260318",
      web_fetch_tool_type: "web_fetch_20260318"
    }
  end
end
