defmodule ContextBot.Mentions.SubjectTest do
  use ExUnit.Case, async: true

  alias ContextBot.Mentions.Subject
  alias ContextBot.Workflow.Invocation

  @bot_did "did:plc:contextbot123aaaaaaaaaa"
  @root_uri "at://did:plc:rootactoraaaaaaaaaaaaaa/app.bsky.feed.post/viral-root"
  @parent_uri "at://#{@bot_did}/app.bsky.feed.post/bot-reply"
  @invocation_uri "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/ask"

  test "detects a follow-up whose parent repo is the bot DID" do
    invocation = invocation(follow_up_notification())

    assert Subject.parent_uri(invocation) == @parent_uri
    assert Subject.parent_by_bot?(invocation, @bot_did)
    refute Subject.parent_by_bot?(invocation, "did:plc:someoneelseaaaaaaaaaaaa")
    refute Subject.parent_by_bot?(invocation, nil)
    assert Subject.thread_root_uri(invocation) == @root_uri
  end

  test "prefers a persisted root_uri over the notification root" do
    persisted = "at://did:plc:rootactoraaaaaaaaaaaaaa/app.bsky.feed.post/canonical"
    invocation = invocation(follow_up_notification(), persisted)

    assert Subject.thread_root_uri(invocation) == persisted
  end

  test "treats a top-level mention as its own thread root" do
    invocation = invocation(%{"uri" => @invocation_uri, "cid" => "bafyask"})

    assert Subject.parent_uri(invocation) == nil
    refute Subject.parent_by_bot?(invocation, @bot_did)
    assert Subject.thread_root_uri(invocation) == @invocation_uri
  end

  defp follow_up_notification do
    %{
      "uri" => @invocation_uri,
      "cid" => "bafyask",
      "record" => %{
        "reply" => %{
          "parent" => %{"uri" => @parent_uri, "cid" => "bafybot"},
          "root" => %{"uri" => @root_uri, "cid" => "bafyroot"}
        }
      }
    }
  end

  defp invocation(raw_notification, root_uri \\ nil) do
    %Invocation{
      invocation_uri: @invocation_uri,
      raw_notification: raw_notification,
      root_uri: root_uri
    }
  end
end
