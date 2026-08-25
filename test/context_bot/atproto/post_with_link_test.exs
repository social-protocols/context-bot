defmodule ContextBot.ATProto.PostWithLinkTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.Post

  @created_at ~U[2026-01-15 12:00:00Z]
  @parent %{"uri" => "at://did:plc:abc/app.bsky.feed.post/3k1", "cid" => "bafycid1"}
  @root %{"uri" => "at://did:plc:abc/app.bsky.feed.post/3k0", "cid" => "bafycid0"}
  @reader_url "https://standard-reader.app/a/did:plc:test/3k123"

  describe "build/5 with reader_url" do
    test "builds record with link facet when reader_url provided" do
      text = "This is the compact reply"

      assert {:ok, record} = Post.build(text, @reader_url, @parent, @root, @created_at)

      assert record["$type"] == "app.bsky.feed.post"
      assert record["text"] == "This is the compact reply (full response)"
      assert record["createdAt"] == "2026-01-15T12:00:00Z"
      assert record["reply"]["parent"] == @parent
      assert record["reply"]["root"] == @root

      assert [facet] = record["facets"]
      assert facet["index"]["byteStart"] == byte_size(text) + byte_size(" (")
      assert facet["index"]["byteEnd"] == byte_size(text <> " (full response")

      assert [feature] = facet["features"]
      assert feature["$type"] == "app.bsky.richtext.facet#link"
      assert feature["uri"] == @reader_url
    end

    test "builds record without facet when reader_url is nil" do
      text = "This is the compact reply"

      assert {:ok, record} = Post.build(text, nil, @parent, @root, @created_at)

      assert record["$type"] == "app.bsky.feed.post"
      assert record["text"] == text
      refute Map.has_key?(record, "facets")
    end

    test "handles unicode in text correctly" do
      text = "Reply with émojis 🎉"

      assert {:ok, record} = Post.build(text, @reader_url, @parent, @root, @created_at)

      expected_text = "Reply with émojis 🎉 (full response)"
      assert record["text"] == expected_text

      # Verify byte positions are correct for unicode
      assert [facet] = record["facets"]
      base_bytes = byte_size(text)
      assert facet["index"]["byteStart"] == base_bytes + byte_size(" (")
    end
  end
end
