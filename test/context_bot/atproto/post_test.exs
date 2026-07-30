defmodule ContextBot.ATProto.PostTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.{Post, StrongRef}

  @created_at ~U[2026-07-29 12:00:00.123456Z]
  @invocation_uri "at://did:plc:invoker/app.bsky.feed.post/3kq3q4abcde2a"
  @root_uri "at://did:plc:root/app.bsky.feed.post/3kq3q4abcde2b"

  test "freezes a reply record using the current invocation and copied root references" do
    {:ok, parent} = StrongRef.new(@invocation_uri, "bafyreicurrent")
    {:ok, root} = StrongRef.new(@root_uri, "bafyreiroot")

    expected = %{
      "$type" => "app.bsky.feed.post",
      "text" => "Concise context.",
      "createdAt" => "2026-07-29T12:00:00.123456Z",
      "reply" => %{
        "parent" => %{"uri" => @invocation_uri, "cid" => "bafyreicurrent"},
        "root" => %{"uri" => @root_uri, "cid" => "bafyreiroot"}
      }
    }

    assert {:ok, record} = Post.build("Concise context.", parent, root, @created_at)
    assert record == expected
  end

  test "uses the current invocation reference as root when no existing root exists" do
    {:ok, parent} = StrongRef.new(@invocation_uri, "bafyreicurrent")

    assert {:ok, %{"reply" => %{"parent" => ^parent, "root" => ^parent}}} =
             Post.build("Concise context.", parent, nil, @created_at)
  end

  test "rejects an invalid parent reference" do
    assert {:error, :invalid_parent} =
             Post.build(
               "Concise context.",
               %{"uri" => @invocation_uri, "cid" => ""},
               nil,
               @created_at
             )
  end
end
