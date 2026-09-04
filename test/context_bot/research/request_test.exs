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
               "citations" => %{"enabled" => true}
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

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V10")
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
    assert Request.structure_prompt() =~ "275 Unicode grapheme"
    refute prompt =~ "at most 300 Unicode grapheme clusters"
    refute prompt =~ "---COMPACT_REPLY---"
    assert prompt =~ "no published"
    assert prompt =~ "reply is needed"
    assert prompt =~ "getcontext.bot is"
    assert prompt =~ "great"
    assert prompt =~ "you should ask getcontext.bot"
    assert prompt =~ "When in doubt, research"
    refute prompt =~ "compact_reply"
    refute prompt =~ "full_response"
    assert prompt =~ "native web_fetch citations"
    assert prompt =~ "Do not return JSON"
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

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V10")
    assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V10"
    assert Request.system_prompt_semantic_version() == "10.0.0"

    assert Request.system_prompt_sha256() ==
             :sha256 |> :crypto.hash(prompt) |> Base.encode16(case: :lower)

    assert Request.system_prompt_rkey() ==
             "prompt-context-bot-system-v10-#{String.slice(Request.system_prompt_sha256(), 0, 16)}"
  end

  test "exposes a stable hashed identity for the versioned structure prompt" do
    prompt = Request.structure_prompt()

    assert String.starts_with?(prompt, "CONTEXT_BOT_STRUCTURE_V3")
    assert Request.structure_prompt_id() == "CONTEXT_BOT_STRUCTURE_V3"
    assert Request.structure_prompt_semantic_version() == "3.0.0"

    assert Request.structure_prompt_sha256() ==
             :sha256 |> :crypto.hash(prompt) |> Base.encode16(case: :lower)

    assert Request.structure_prompt_rkey() ==
             "prompt-context-bot-structure-v3-#{String.slice(Request.structure_prompt_sha256(), 0, 16)}"
  end

  test "projects allowlisted Messages parameters and the first user message" do
    request = Request.initial(@canonical_thread, config())

    projection =
      Request.public_projection(request, %{
        anthropic_api_version: "2023-06-01",
        research_max_tokens: 4_096
      })

    assert projection.prompt.id == "CONTEXT_BOT_SYSTEM_V10"
    assert projection.prompt.semantic_version == "10.0.0"
    assert projection.prompt.sha256 == Request.system_prompt_sha256()
    assert projection.parameters["anthropic-version"] == "2023-06-01"
    assert projection.parameters["model"] == "claude-sonnet-5"
    assert projection.parameters["max_tokens"] == 4_096
    assert projection.parameters["effort"] == "medium"
    refute Map.has_key?(projection.parameters, "output_format")
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
               "citations" => true
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

  test "V10 research prompt and structure schema require answering the invoker's questions first" do
    prompt = Request.system_prompt()
    normalized = String.replace(prompt, ~r/\s+/, " ")
    schema = Request.structure_schema()
    compact = structure_variant(schema, "reply")["properties"]["compact_reply"]["description"]
    structure = String.replace(Request.structure_prompt(), ~r/\s+/, " ")

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V10")
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
    refute Map.has_key?(structure_variant(schema, "reply")["properties"], "full_response")
    refute Map.has_key?(structure_variant(schema, "no_reply")["properties"], "full_response")

    assert structure =~ "Open by directly answering each asked question"
    assert structure =~ "Do not include a full_response field"
  end

  test "structure schema anyOf requires nonempty compact_reply when disposition is reply" do
    schema = Request.structure_schema()
    encoded = Jason.encode!(schema)
    reply = structure_variant(schema, "reply")
    no_reply = structure_variant(schema, "no_reply")
    compact = reply["properties"]["compact_reply"]
    structure = String.replace(Request.structure_prompt(), ~r/\s+/, " ")

    assert String.starts_with?(Request.structure_prompt(), "CONTEXT_BOT_STRUCTURE_V3")
    assert Request.structure_prompt_id() == "CONTEXT_BOT_STRUCTURE_V3"
    assert Request.structure_prompt_semantic_version() == "3.0.0"
    assert structure =~ "compact_reply is the Bluesky"
    assert structure =~ "title is a short"
    assert structure =~ "Never put the published answer only in title"

    assert is_list(schema["anyOf"])
    assert length(schema["anyOf"]) == 2
    assert reply["required"] == ["disposition", "title", "compact_reply"]
    assert no_reply["required"] == ["disposition", "title", "compact_reply"]
    assert reply["additionalProperties"] == false
    assert no_reply["additionalProperties"] == false
    assert reply["properties"]["disposition"]["const"] == "reply"
    assert no_reply["properties"]["disposition"]["const"] == "no_reply"
    assert compact["pattern"] == ~S"[\s\S]+"
    refute Map.has_key?(compact, "minLength")
    refute Map.has_key?(compact, "maxLength")
    refute encoded =~ "minLength"
    refute encoded =~ "maxLength"
    refute Map.has_key?(reply["properties"], "full_response")
    refute Map.has_key?(no_reply["properties"], "full_response")

    refute structure_schema_accepts?(schema, %{
             "disposition" => "reply",
             "title" => "The stuffed Bluesky answer that belongs in compact_reply",
             "compact_reply" => ""
           })

    assert structure_schema_accepts?(schema, %{
             "disposition" => "reply",
             "title" => "What Is That Bird?",
             "compact_reply" => "A Himalayan Monal."
           })

    assert structure_schema_accepts?(schema, %{
             "disposition" => "no_reply",
             "title" => "",
             "compact_reply" => ""
           })
  end

  test "V10 research prompt uses native citations instead of a full_response schema field" do
    prompt = Request.system_prompt()
    normalized = String.replace(prompt, ~r/\s+/, " ")
    schema = Request.output_schema()
    compact = structure_variant(schema, "reply")["properties"]["compact_reply"]["description"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V10")
    assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V10"
    assert Request.system_prompt_semantic_version() == "10.0.0"
    assert normalized =~ "native web_fetch citations"
    assert normalized =~ "Do not invent URLs"
    refute Map.has_key?(structure_variant(schema, "reply")["properties"], "full_response")
    refute Map.has_key?(structure_variant(schema, "no_reply")["properties"], "full_response")

    assert compact =~ "plain text"
    assert compact =~ "without markdown"
    refute compact =~ "[label](https://"
    refute compact =~ "Sources section"
  end

  test "V10 research and structure prompts write in the invoking mention language" do
    prompt = Request.system_prompt()
    normalized = String.replace(prompt, ~r/\s+/, " ")
    structure = String.replace(Request.structure_prompt(), ~r/\s+/, " ")
    schema = Request.structure_schema()
    reply = structure_variant(schema, "reply")
    title = reply["properties"]["title"]["description"]
    compact = reply["properties"]["compact_reply"]["description"]

    assert String.starts_with?(prompt, "CONTEXT_BOT_SYSTEM_V10")
    assert String.starts_with?(Request.structure_prompt(), "CONTEXT_BOT_STRUCTURE_V3")
    assert Request.structure_prompt_id() == "CONTEXT_BOT_STRUCTURE_V3"
    assert Request.system_prompt_id() == "CONTEXT_BOT_SYSTEM_V10"
    assert Request.system_prompt_semantic_version() == "10.0.0"

    assert normalized =~ "same language as the invoking mention"
    assert normalized =~ "Do not default to English"
    assert structure =~ "same language as the invoking mention"
    assert structure =~ "Do not default to English"
    assert title =~ "same language as the invoking mention"
    assert compact =~ "same language as the invoking mention"
    assert TitlePrompt.prompt() =~ "same language as the invoking mention"
    assert TitlePrompt.schema_description() =~ "same language as the invoking mention"
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
    refute Map.has_key?(request, "thinking")
    refute Map.has_key?(request, "effort")
    refute Map.has_key?(request["output_config"], "effort")
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

  test "research request omits JSON schema; structure request is schema-only and tool-free" do
    research = Request.initial(@canonical_thread, config())
    schema = Request.structure_schema()

    structure =
      Request.structure(%{
        model_id: "claude-sonnet-5",
        max_tokens: 1_024,
        writeup: "Cited writeup.",
        citations: [%{"url" => "https://primary.example/report", "cited_text" => "excerpt"}],
        canonical_thread: @canonical_thread.text
      })

    assert research["thinking"] == %{"type" => "adaptive"}
    assert research["output_config"]["effort"] == "medium"
    refute Map.has_key?(research["output_config"], "format")
    assert Enum.at(research["tools"], 1)["citations"] == %{"enabled" => true}
    refute Jason.encode!(research) =~ "json_schema"

    refute Map.has_key?(structure, "tools")
    refute Map.has_key?(structure, "thinking")
    refute Map.has_key?(structure, "effort")
    refute Map.has_key?(structure["output_config"], "effort")
    refute Jason.encode!(structure) =~ "adaptive"
    assert structure["output_config"]["format"]["type"] == "json_schema"
    assert structure["output_config"]["format"]["schema"] == schema

    assert structure_variant(schema, "reply")["required"] == [
             "disposition",
             "title",
             "compact_reply"
           ]

    assert structure_variant(schema, "no_reply")["required"] == [
             "disposition",
             "title",
             "compact_reply"
           ]

    refute Map.has_key?(structure_variant(schema, "reply")["properties"], "full_response")
    refute Map.has_key?(structure_variant(schema, "no_reply")["properties"], "full_response")
    assert Request.structure_request?(structure)
    refute Request.structure_request?(research)
    assert structure["messages"] |> hd() |> Map.get("content") =~ "STRUCTURE_OUTPUT"
    assert structure["messages"] |> hd() |> Map.get("content") =~ "https://primary.example/report"
    refute Jason.encode!(structure) =~ "maxLength"
    refute Jason.encode!(structure) =~ "minLength"
  end

  test "structure ignores optional effort and stays Haiku-safe" do
    structure =
      Request.structure(%{
        model_id: "claude-haiku-4-5",
        max_tokens: 1_024,
        writeup: "Cited writeup.",
        citations: [],
        canonical_thread: @canonical_thread.text,
        effort: :low
      })

    refute Map.has_key?(structure, "thinking")
    refute Map.has_key?(structure, "effort")
    refute Map.has_key?(structure["output_config"], "effort")
    assert structure["output_config"]["format"]["type"] == "json_schema"
    assert structure["output_config"]["format"]["schema"] == Request.structure_schema()
  end

  defp structure_variant(schema, disposition) do
    schema
    |> Map.fetch!("anyOf")
    |> Enum.find(&(&1["properties"]["disposition"]["const"] == disposition))
  end

  defp structure_schema_accepts?(schema, payload) do
    Enum.any?(schema["anyOf"] || [], &object_schema_accepts?(&1, payload))
  end

  defp object_schema_accepts?(variant, payload) when is_map(variant) and is_map(payload) do
    props = variant["properties"] || %{}
    required = variant["required"] || []
    extra_keys = Map.keys(payload) -- Map.keys(props)

    Enum.all?(required, &Map.has_key?(payload, &1)) and
      (variant["additionalProperties"] != false or extra_keys == []) and
      Enum.all?(payload, fn {key, value} ->
        field_accepts?(Map.get(props, key), value)
      end)
  end

  defp object_schema_accepts?(_variant, _payload), do: false

  defp field_accepts?(%{"const" => const}, value), do: value == const

  defp field_accepts?(%{"type" => "string", "pattern" => pattern}, value) when is_binary(value) do
    Regex.match?(Regex.compile!(pattern), value)
  end

  defp field_accepts?(%{"type" => "string"}, value), do: is_binary(value)
  defp field_accepts?(_field, _value), do: false

  defp assert_output_config(request, effort) do
    assert request["output_config"]["effort"] == effort
    refute Map.has_key?(request["output_config"], "format")
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
