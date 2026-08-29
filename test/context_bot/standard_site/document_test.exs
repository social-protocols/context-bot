defmodule ContextBot.StandardSite.DocumentTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.StandardSite.Document

  @repo "did:plc:test123abc"
  @publication_uri "at://#{@repo}/site.standard.publication/context-bot"
  @created_at ~U[2026-08-25 12:00:00Z]
  @prompt_reader_url "https://standard-reader.app/a/#{@repo}/prompt-context-bot-system-v5-testhash"
  @content %{
    full_response: "This is the full research response with detailed analysis.",
    selected_reply: "Compact summary here.",
    invocation_uri: "at://did:plc:abc/app.bsky.feed.post/3k123",
    prompt: %{
      id: "CONTEXT_BOT_SYSTEM_V5",
      semantic_version: "5.0.0",
      sha256: "abc123def456",
      reader_url: @prompt_reader_url
    },
    parameters: %{
      "anthropic-version" => "2023-06-01",
      "model" => "claude-sonnet-5",
      "max_tokens" => 4096,
      "effort" => "medium",
      "thinking" => "adaptive",
      "tool_choice" => "auto",
      "cache_control" => "ephemeral",
      "continuation" => false,
      "length_repair" => false,
      "tools" => [
        %{
          "type" => "web_search_20260318",
          "name" => "web_search",
          "allowed_callers" => ["direct"],
          "max_uses" => 2,
          "response_inclusion" => "excluded"
        }
      ]
    },
    user_message: %{
      "text" => "CONTEXT_BOT_THREAD_V1\n\n[invocation]\nPlease add context.",
      "images" => [
        %{
          "url" =>
            "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
        }
      ]
    },
    asked_text: "What bird is that?",
    parent_uri: "at://did:plc:bob/app.bsky.feed.post/3parentrkey12"
  }

  defmodule TrackingDocClient do
    @moduledoc false

    def put_record(_repo, _collection, _rkey, record) do
      send(self(), {:document_put, record})
      {:ok, 200, %{}, %{}}
    end
  end

  describe "create/5" do
    test "creates a document record successfully" do
      assert {:ok, result} =
               Document.create(
                 FakeDocClientSuccess,
                 @repo,
                 @publication_uri,
                 @content,
                 @created_at
               )

      assert is_binary(result.uri)
      assert is_binary(result.rkey)
      assert is_binary(result.reader_url)
      assert String.starts_with?(result.reader_url, "https://standard-reader.app/a/")
    end

    test "returns error when put_record fails" do
      assert {:error, :timeout} =
               Document.create(
                 FakeDocClientFailure,
                 @repo,
                 @publication_uri,
                 @content,
                 @created_at
               )
    end

    test "refuses to publish when the prompt reader URL is missing" do
      content = %{@content | prompt: Map.delete(@content.prompt, :reader_url)}

      assert {:error, :prompt_inputs_missing} =
               Document.create(
                 FakeDocClientSuccess,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )
    end

    test "refuses to publish when the prompt reader URL is not a Standard Reader URL" do
      content = put_in(@content, [:prompt, :reader_url], "https://example.test/prompt")

      assert {:error, :prompt_inputs_missing} =
               Document.create(
                 FakeDocClientSuccess,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )
    end

    test "maps title and description from the question, not the rkey or reply" do
      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 @content,
                 @created_at
               )

      assert_received {:document_put, record}
      assert record["title"] == "What bird is that?"
      assert record["description"] == "What bird is that?"
      refute record["title"] =~ "Context on"
      refute record["title"] =~ "3k123"
      refute record["description"] =~ @content.selected_reply
    end

    test "falls back to truncated invocation text when the model title is junk" do
      asked =
        "Can you help me understand the historical context of this planned explosion near the harbor?"

      content =
        @content
        |> Map.put(:asked_text, asked)
        |> Map.put(:document_title, "Context on 3k123...")
        |> Map.put(:selected_reply, "The blast was a planned demolition.")

      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )

      assert_received {:document_put, record}
      assert record["title"] == "Can you help me understand the"
      assert record["description"] == asked
    end
  end

  describe "format_markdown/1" do
    test "includes the writeup, prompt link, hashed identity, parameters, and thread" do
      markdown = Document.format_markdown(@content)

      assert markdown =~ "# Research Analysis"
      assert markdown =~ @content.full_response
      assert markdown =~ "## Summary"
      assert markdown =~ @content.selected_reply
      assert markdown =~ "[CONTEXT_BOT_SYSTEM_V5](#{@prompt_reader_url})"
      assert markdown =~ "Semantic version: `5.0.0`"
      assert markdown =~ "SHA-256: `abc123def456`"
      assert markdown =~ "`anthropic-version`: 2023-06-01"
      assert markdown =~ "`model`: claude-sonnet-5"
      assert markdown =~ "`max_tokens`: 4096"
      assert markdown =~ "`effort`: medium"
      assert markdown =~ "`thinking`: adaptive"
      assert markdown =~ "`tool_choice`: auto"
      assert markdown =~ "`cache_control`: ephemeral"
      assert markdown =~ "`continuation`: false"
      assert markdown =~ "`length_repair`: false"
      assert markdown =~ "`web_search` (web_search_20260318)"
      assert markdown =~ "allowed_callers=[\"direct\"]"
      assert markdown =~ "CONTEXT_BOT_THREAD_V1"

      assert markdown =~
               "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"

      assert markdown =~ "Hidden model reasoning is not available"
      assert markdown =~ "do not guarantee an identical Claude response"
      refute markdown =~ "x-api-key"
      refute markdown =~ "authorization"
    end

    test "places an Asked block with the invocation and parent links before the writeup" do
      markdown = Document.format_markdown(@content)
      asked_at = :binary.match(markdown, "## Asked") |> elem(0)
      analysis_at = :binary.match(markdown, "# Research Analysis") |> elem(0)

      assert asked_at < analysis_at
      assert markdown =~ "What bird is that?"
      assert markdown =~ "https://bsky.app/profile/did:plc:abc/post/3k123"
      assert markdown =~ "https://bsky.app/profile/did:plc:bob/post/3parentrkey12"
    end

    test "omits the parent link when the invoking post is not a reply" do
      markdown = Document.format_markdown(Map.delete(@content, :parent_uri))

      assert markdown =~ "## Asked"
      assert markdown =~ "https://bsky.app/profile/did:plc:abc/post/3k123"
      refute markdown =~ "3parentrkey12"
    end
  end

  describe "reader_url_from_uri/1" do
    test "converts a stored document AT URI into the Standard Reader URL" do
      uri = "at://did:plc:test123abc/site.standard.document/3k123abc"

      assert Document.reader_url_from_uri(uri) ==
               "https://standard-reader.app/a/did:plc:test123abc/3k123abc"
    end

    test "returns nil when the URI is missing or not a Standard.site document" do
      assert Document.reader_url_from_uri(nil) == nil
      assert Document.reader_url_from_uri("") == nil
      assert Document.reader_url_from_uri("https://example.com/doc") == nil
      assert Document.reader_url_from_uri("at://did:plc:test/app.bsky.feed.post/3k123") == nil
      assert Document.reader_url_from_uri("at://did:plc:test/site.standard.document/") == nil
    end
  end

  describe "add_post_ref/4" do
    test "updates document with bskyPostRef" do
      post_uri = "at://did:plc:abc/app.bsky.feed.post/3k456"

      assert :ok = Document.add_post_ref(FakeDocClientWithDocument, @repo, "3k123", post_uri)
    end

    test "returns error when document doesn't exist" do
      post_uri = "at://did:plc:abc/app.bsky.feed.post/3k456"

      assert {:error, :record_not_found} =
               Document.add_post_ref(FakeDocClientNotFound, @repo, "3k123", post_uri)
    end
  end
end
