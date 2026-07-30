defmodule ContextBot.ATProto.TIDTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.{ATURI, TID}

  test "generates lowercase base32 TIDs that sort in timestamp order" do
    earlier = TID.generate(1_722_320_000_000_000)
    later = TID.generate(1_722_320_000_000_001)

    assert String.match?(earlier, ~r/\A[234567abcdefghijklmnopqrstuvwxyz]{13}\z/)
    assert String.match?(later, ~r/\A[234567abcdefghijklmnopqrstuvwxyz]{13}\z/)
    assert earlier < later
  end

  test "generates a fresh record key instead of reusing the source record key" do
    source_uri = "at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a"
    assert {:ok, %{rkey: source_rkey}} = ATURI.parse(source_uri)

    refute TID.generate(1_722_320_000_000_000) == source_rkey
  end
end
