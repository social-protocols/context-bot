defmodule ContextBot.StandardSite.DocumentTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.Research.Drafts
  alias ContextBot.StandardSite.Document

  @repo "did:plc:test123abc"
  @publication_uri "at://#{@repo}/site.standard.publication/context-bot"
  @created_at ~U[2026-08-25 12:00:00Z]
  @prompt_reader_url "https://standard-reader.app/a/#{@repo}/prompt-context-bot-system-v5-testhash"
  @structure_prompt_reader_url "https://standard-reader.app/a/#{@repo}/prompt-context-bot-structure-v2-testhash"
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
    structure_prompt: %{
      id: "CONTEXT_BOT_STRUCTURE_V2",
      semantic_version: "2.0.0",
      sha256: "structurehash789",
      reader_url: @structure_prompt_reader_url
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
    asked_text: "What bird is that?",
    parent_uri: "at://did:plc:bob/app.bsky.feed.post/3parentrkey12",
    invoker_handle: "alice.test",
    parent_handle: "bob.test",
    document_reader_url: "https://standard-reader.app/a/#{@repo}/3kfullresp"
  }

  defmodule TrackingDocClient do
    @moduledoc false

    def put_record(_repo, _collection, _rkey, record) do
      send(self(), {:document_put, record})
      {:ok, 200, %{}, %{}}
    end
  end

  defmodule TrackingDocClientWithDocument do
    @moduledoc false

    def get_record(repo, collection, rkey) do
      FakeDocClientWithDocument.get_record(repo, collection, rkey)
    end

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

    test "refuses to publish when the structure prompt identity is missing" do
      content = Map.delete(@content, :structure_prompt)

      assert {:error, :prompt_inputs_missing} =
               Document.create(
                 FakeDocClientSuccess,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )
    end

    test "refuses to publish when the structure prompt reader URL is not a Standard Reader URL" do
      content = put_in(@content, [:structure_prompt, :reader_url], "https://example.test/prompt")

      assert {:error, :prompt_inputs_missing} =
               Document.create(
                 FakeDocClientSuccess,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )
    end

    test "publishes without a user_message dump" do
      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 @content,
                 @created_at
               )

      assert_received {:document_put, record}
      markdown = record["content"]["text"]["markdown"]
      refute markdown =~ "### Canonical thread"
      refute markdown =~ "CONTEXT_BOT_THREAD_V1"
      refute markdown =~ "The first user message sent to the Messages API"
    end

    test "omits bskyPostRef at create time because the reply is not published yet" do
      content =
        @content
        |> Map.put(:reply_uri, "at://did:plc:contextbot123/app.bsky.feed.post/3kreply")
        |> Map.put(:reply_cid, "bafyreireplycid1")

      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )

      assert_received {:document_put, record}
      refute Map.has_key?(record, "bskyPostRef")
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

    test "uses a Title Case model headline and keeps mentions in the description" do
      launch =
        "I have just launched @getcontext.bot. Mention it in a post or reply and get a response from Claude. @getcontext.bot, say hello!"

      content =
        @content
        |> Map.put(:asked_text, launch)
        |> Map.put(:document_title, "Context Bot Launch")
        |> Map.put(:selected_reply, "Hello! I'm @getcontext.bot.")

      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 content,
                 @created_at
               )

      assert_received {:document_put, record}
      assert record["title"] == "Context Bot Launch"
      assert record["description"] == launch
      refute record["title"] == "I have just launched. Mention."
      refute record["description"] =~ "launched ."
    end

    test "falls back to a sentence of the raw invocation when the model title is junk" do
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
      refute record["title"] == "Can you help me understand the"
      refute record["title"] =~ "Context on"
      refute record["title"] =~ "3k123"
      assert String.starts_with?(asked, record["title"])
      assert record["description"] == asked
    end

    test "published document body has no CONTEXT_BOT_DRAFT markers" do
      essay = "This is the full research response with detailed analysis."
      writeup = Drafts.format("What Is That Bird?", "A Himalayan Monal.") <> "\n\n" <> essay

      assert {:ok, _result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 %{@content | full_response: writeup},
                 @created_at
               )

      assert_received {:document_put, record}
      markdown = record["content"]["text"]["markdown"]

      assert record["textContent"] == essay
      refute record["textContent"] =~ Drafts.open_marker()
      assert markdown =~ essay
      refute markdown =~ Drafts.open_marker()
      refute markdown =~ Drafts.close_marker()
    end

    test "publishes a Claude continue link that names this document's reader URL" do
      assert {:ok, result} =
               Document.create(
                 TrackingDocClient,
                 @repo,
                 @publication_uri,
                 @content,
                 @created_at
               )

      assert_received {:document_put, record}
      markdown = record["content"]["text"]["markdown"]
      href = continue_href(markdown)
      query = continue_query(href)

      assert href =~ "https://claude.ai/new?q="
      assert query =~ result.reader_url
      refute query =~ @content.full_response
      refute query =~ "CONTEXT_BOT_SYSTEM_V5"
      refute href =~ @content.full_response
      refute href =~ "attachment="
      refute href =~ "claude://"
    end
  end

  describe "format_markdown/1" do
    test "includes the writeup, both prompt links, hashed identities, and parameters" do
      markdown = Document.format_markdown(@content)

      assert markdown =~ "# Research Analysis"
      assert markdown =~ @content.full_response
      assert markdown =~ "## Summary"
      assert markdown =~ @content.selected_reply
      assert markdown =~ "[CONTEXT_BOT_SYSTEM_V5](#{@prompt_reader_url})"
      assert markdown =~ "[CONTEXT_BOT_STRUCTURE_V2](#{@structure_prompt_reader_url})"
      assert markdown =~ "Semantic version: `5.0.0`"
      assert markdown =~ "Semantic version: `2.0.0`"
      assert markdown =~ "SHA-256: `abc123def456`"
      assert markdown =~ "SHA-256: `structurehash789`"
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
      refute markdown =~ "### Canonical thread"
      refute markdown =~ "CONTEXT_BOT_THREAD_V1"
      refute markdown =~ "The first user message sent to the Messages API"

      refute markdown =~
               "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"

      assert markdown =~ "Hidden model reasoning is not available"
      assert markdown =~ "do not guarantee an identical Claude response"
      refute markdown =~ "x-api-key"
      refute markdown =~ "authorization"
    end

    test "ignores a leftover user_message instead of dumping it" do
      markdown =
        Document.format_markdown(
          Map.put(@content, :user_message, %{
            "text" => "STRUCTURE_OUTPUT\n\nCanonical thread:\n\nPlease add context.",
            "images" => [
              %{
                "url" =>
                  "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
              }
            ]
          })
        )

      refute markdown =~ "### Canonical thread"
      refute markdown =~ "STRUCTURE_OUTPUT"
      refute markdown =~ "Please add context."

      refute markdown =~
               "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:author/bafkreiaurora@jpeg"
    end

    test "places a reply responding-to line before the writeup and does not repeat the question" do
      markdown = Document.format_markdown(@content)
      responding_at = match_at(markdown, "Responding to")
      analysis_at = match_at(markdown, "# Research Analysis")
      block = responding_block(markdown)

      assert responding_at < analysis_at
      refute markdown =~ "## Asked"
      refute block =~ "What bird is that?"

      assert block ==
               "Responding to [@alice.test](https://bsky.app/profile/alice.test/post/3k123)'s reply to [@bob.test](https://bsky.app/profile/bob.test/post/3parentrkey12)'s post."
    end

    test "includes a Claude continue link that names a getcontext.bot mirror URL" do
      content =
        Map.put(
          @content,
          :document_reader_url,
          "https://getcontext.bot/r/31"
        )

      markdown = Document.format_markdown(content)
      href = continue_href(markdown)
      query = continue_query(href)

      assert query =~ "https://getcontext.bot/r/31"
      refute query =~ "https://standard-reader.app/a/#{@repo}/3kfullresp"
    end

    test "places the compact summary first, then responding-to, writeup, continue link, and metadata" do
      markdown = Document.format_markdown(@content)
      summary_at = match_at(markdown, "## Summary")
      selected_at = match_at(markdown, @content.selected_reply)
      responding_at = match_at(markdown, "Responding to")
      analysis_at = match_at(markdown, "# Research Analysis")
      continue_at = match_at(markdown, "Continue this conversation in Claude")
      metadata_at = match_at(markdown, "## How this response was produced")
      href = continue_href(markdown)
      query = continue_query(href)

      assert summary_at < selected_at
      assert selected_at < responding_at
      assert responding_at < analysis_at
      assert analysis_at < continue_at
      assert continue_at < metadata_at
      assert href =~ "https://claude.ai/new?q="
      assert query =~ @content.document_reader_url
      refute query =~ @content.full_response
      refute query =~ "CONTEXT_BOT_SYSTEM_V5"
      refute href =~ @content.full_response
      refute href =~ "attachment="
      refute href =~ "claude://"
    end

    test "strips CONTEXT_BOT_DRAFT from the published writeup and leaves the essay" do
      essay = "This is the full research response with detailed analysis."
      writeup = Drafts.format("What Is That Bird?", "A Himalayan Monal.") <> "\n\n" <> essay
      content = %{@content | full_response: writeup}
      markdown = Document.format_markdown(content)

      assert markdown =~ essay
      refute markdown =~ Drafts.open_marker()
      refute markdown =~ Drafts.close_marker()
      refute markdown =~ "title: What Is That Bird?"
      refute markdown =~ "compact_reply: A Himalayan Monal."
      assert Document.format_markdown(%{@content | full_response: essay}) =~ essay
    end

    test "uses the root sentence when the invoking post is not a reply" do
      markdown = Document.format_markdown(Map.delete(@content, :parent_uri))
      block = responding_block(markdown)

      assert block ==
               "Responding to [@alice.test](https://bsky.app/profile/alice.test/post/3k123)'s post."

      refute markdown =~ "## Asked"
      refute markdown =~ "3parentrkey12"
      refute block =~ "What bird is that?"
    end
  end

  describe "reader_url_from_uri/1" do
    test "converts a stored document AT URI into the Standard Reader URL" do
      uri = "at://did:plc:test123abc/site.standard.document/3k123abc"

      assert Document.parse_document_uri(uri) ==
               {:ok, %{did: "did:plc:test123abc", rkey: "3k123abc"}}

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

  describe "add_post_ref/5" do
    test "writes bskyPostRef as a typed strongRef of the published reply" do
      reply_uri = "at://did:plc:contextbot123/app.bsky.feed.post/3kreplypart1"
      reply_cid = "bafyreireplycid1"
      invocation_uri = "at://did:plc:abc/app.bsky.feed.post/3k123"

      assert :ok =
               Document.add_post_ref(
                 TrackingDocClientWithDocument,
                 @repo,
                 "3k123",
                 reply_uri,
                 reply_cid
               )

      assert_received {:document_put, record}

      assert record["bskyPostRef"] == %{
               "$type" => "com.atproto.repo.strongRef",
               "uri" => reply_uri,
               "cid" => reply_cid
             }

      refute is_binary(record["bskyPostRef"])
      refute record["bskyPostRef"]["uri"] == invocation_uri
    end

    test "returns error when the reply uri or cid is not a strongRef" do
      assert {:error, :invalid_uri} =
               Document.add_post_ref(
                 TrackingDocClientWithDocument,
                 @repo,
                 "3k123",
                 "at://did:plc:abc/site.standard.document/3k123",
                 "bafyreireplycid1"
               )

      assert {:error, :invalid_cid} =
               Document.add_post_ref(
                 TrackingDocClientWithDocument,
                 @repo,
                 "3k123",
                 "at://did:plc:abc/app.bsky.feed.post/3kreplypart1",
                 ""
               )

      refute_received {:document_put, _record}
    end

    test "returns error when document doesn't exist" do
      reply_uri = "at://did:plc:abc/app.bsky.feed.post/3k456"

      assert {:error, :record_not_found} =
               Document.add_post_ref(
                 FakeDocClientNotFound,
                 @repo,
                 "3k123",
                 reply_uri,
                 "bafyreireplycid1"
               )
    end
  end

  defp match_at(markdown, pattern) do
    case :binary.match(markdown, pattern) do
      {pos, _len} -> pos
      :nomatch -> flunk("missing #{inspect(pattern)}")
    end
  end

  defp responding_block(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "Responding to "))
  end

  defp continue_href(markdown) do
    assert [_, href] =
             Regex.run(
               ~r/\[Continue this conversation in Claude\]\((https:\/\/claude\.ai\/new\?q=[^)]+)\)/,
               markdown
             )

    href
  end

  defp continue_query(href) do
    %URI{query: query} = URI.parse(href)
    assert %{"q" => q} = URI.decode_query(query)
    q
  end
end
