defmodule ContextBot.Reply.IntentTest do
  use ExUnit.Case, async: true

  alias ContextBot.Reply.Intent
  alias ContextBot.Workflow.Invocation

  @created_at ~U[2026-08-24 12:34:56.123456Z]
  @rkey "3mzzzzzzzzzzz"

  test "builds an exact deterministic reply intent" do
    invocation = invocation()

    assert {:ok, intent} =
             Intent.build(
               invocation,
               "A bounded reply.",
               "did:plc:contextbot",
               @created_at,
               fn _timestamp -> @rkey end
             )

    assert intent.reply_repo == "did:plc:contextbot"
    assert intent.reply_rkey == @rkey

    assert intent.reply_record == %{
             "$type" => "app.bsky.feed.post",
             "text" => "A bounded reply.",
             "createdAt" => "2026-08-24T12:34:56.123456Z",
             "reply" => %{
               "parent" => %{
                 "uri" => invocation.invocation_uri,
                 "cid" => invocation.current_cid
               },
               "root" => %{
                 "uri" => invocation.root_uri,
                 "cid" => invocation.root_cid
               }
             }
           }
  end

  test "uses the parent as root only when both stored root fields are absent" do
    invocation = %{invocation() | root_uri: nil, root_cid: nil}

    assert {:ok, %{reply_record: record}} =
             Intent.build(invocation, "Reply.", "did:plc:contextbot", @created_at, fn _ ->
               @rkey
             end)

    assert record["reply"]["root"] == record["reply"]["parent"]
  end

  test "rejects invalid publication identities and strong references" do
    valid = invocation()

    assert {:error, :invalid_publication_repo} =
             Intent.build(valid, "Reply.", "not-a-did", @created_at, fn _ -> @rkey end)

    assert {:error, :invalid_parent} =
             Intent.build(
               %{valid | current_cid: ""},
               "Reply.",
               "did:plc:contextbot",
               @created_at,
               fn _ -> @rkey end
             )

    assert {:error, :invalid_root} =
             Intent.build(
               %{valid | root_cid: nil},
               "Reply.",
               "did:plc:contextbot",
               @created_at,
               fn _ -> @rkey end
             )
  end

  defp invocation do
    %Invocation{
      invocation_uri: "at://did:plc:alice/app.bsky.feed.post/invocation",
      current_cid: "bafy-current",
      root_uri: "at://did:plc:root/app.bsky.feed.post/root",
      root_cid: "bafy-root"
    }
  end
end
