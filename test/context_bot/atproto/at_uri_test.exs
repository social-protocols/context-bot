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
end
