defmodule ContextBot.ATProto.TIDTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.{ATURI, TID}

  test "generates lowercase base32 TIDs that sort in timestamp order" do
    earlier = TID.generate(1_722_320_000_000_000)
    later = TID.generate(1_722_320_000_000_001)

    assert String.match?(
             earlier,
             ~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/
           )

    assert String.match?(later, ~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
    assert earlier < later
  end

  test "generates distinct valid TIDs for the same timestamp" do
    first = TID.generate(1_722_320_000_000_000)
    second = TID.generate(1_722_320_000_000_000)

    refute first == second
    assert String.match?(first, ~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
    assert String.match?(second, ~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
  end

  test "rejects timestamps outside the 53-bit ATProto TID range" do
    assert String.match?(
             TID.generate(9_007_199_254_740_991),
             ~r/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/
           )

    assert_raise FunctionClauseError, fn ->
      TID.generate(-1)
    end

    assert_raise FunctionClauseError, fn ->
      TID.generate(9_007_199_254_740_992)
    end
  end

  test "generates a fresh record key instead of reusing the source record key" do
    source_uri = "at://did:plc:alice/app.bsky.feed.post/3kq3q4abcde2a"
    assert {:ok, %{rkey: source_rkey}} = ATURI.parse(source_uri)

    refute TID.generate(1_722_320_000_000_000) == source_rkey
  end
end
