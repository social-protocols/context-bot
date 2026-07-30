defmodule ContextBot.ATProto.ATURITest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.ATURI

  test "parses a post AT URI into its repository, collection, and record key" do
    assert {:ok,
            %{
              repo: "did:plc:alice",
              collection: "app.bsky.feed.post",
              rkey: "3kq3q4abcde2a"
            }} = ATURI.parse("at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a")
  end

  test "rejects URIs that are not exactly post record URIs" do
    for uri <- [
          "https://bsky.app/profile/did:plc:alice/post/3kq3q4abcde2a",
          "at://did:plc:alice/app.bsky.feed.like/3kq3q4abcde2a",
          "at://did:plc:alice/app.bsky.feed.post",
          "at://did:plc:alice/app.bsky.feed.post/",
          "at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a?view=1",
          "at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a/extra"
        ] do
      assert :error == ATURI.parse(uri)
    end
  end

  test "rejects record keys outside the ATProto grammar" do
    for rkey <- [".", "..", "contains space", "@handle", String.duplicate("a", 513)] do
      assert :error == ATURI.parse("at://did:plc:alice/app.bsky.feed.post/#{rkey}")
    end
  end

  test "requires a lowercase-letter DID method and valid method-specific identifier" do
    assert {:ok, %{repo: "did:web:example.com:profile%2Fcontext"}} =
             ATURI.parse(
               "at://did:web:example.com:profile%2Fcontext/app.bsky.feed.post/3kq3q4abcde2a"
             )

    for did <- [
          "did:plc1:alice",
          "did:web:example.com:",
          "did:web:example.com%",
          "did:web:example%2",
          "did:web:example%zz"
        ] do
      assert :error == ATURI.parse("at://#{did}/app.bsky.feed.post/3kq3q4abcde2a")
    end
  end

  test "accepts DIDs up to 2,048 characters and rejects longer DIDs" do
    maximum_did = "did:web:" <> String.duplicate("a", 2_040)
    too_long_did = "did:web:" <> String.duplicate("a", 2_041)

    assert byte_size(maximum_did) == 2_048

    assert {:ok, %{repo: ^maximum_did}} =
             ATURI.parse("at://#{maximum_did}/app.bsky.feed.post/3kq3q4abcde2a")

    assert :error == ATURI.parse("at://#{too_long_did}/app.bsky.feed.post/3kq3q4abcde2a")
  end
end
