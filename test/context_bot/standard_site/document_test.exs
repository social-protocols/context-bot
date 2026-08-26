defmodule ContextBot.StandardSite.DocumentTest do
  use ContextBot.DataCase, async: true

  alias ContextBot.StandardSite.Document

  @repo "did:plc:test123abc"
  @publication_uri "at://#{@repo}/site.standard.publication/context-bot"
  @created_at ~U[2026-08-25 12:00:00Z]
  @content %{
    full_response: "This is the full research response with detailed analysis.",
    selected_reply: "Compact summary here.",
    invocation_uri: "at://did:plc:abc/app.bsky.feed.post/3k123"
  }

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
