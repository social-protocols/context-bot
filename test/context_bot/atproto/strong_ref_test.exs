defmodule ContextBot.ATProto.StrongRefTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.StrongRef

  @uri "at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a"

  test "builds the ATProto strong-reference shape" do
    assert {:ok, %{"uri" => @uri, "cid" => "bafyreialice"}} =
             StrongRef.new(@uri, "bafyreialice")
  end

  test "rejects a URI outside the post collection" do
    assert {:error, :invalid_uri} =
             StrongRef.new("at://did:plc:alice/app.bsky.feed.like/3kq3q4abcde2a", "bafyreialice")
  end

  test "rejects an empty CID" do
    assert {:error, :invalid_cid} = StrongRef.new(@uri, "")
  end
end
