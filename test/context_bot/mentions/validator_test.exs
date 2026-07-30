defmodule ContextBot.Mentions.ValidatorTest do
  use ExUnit.Case, async: true

  alias ContextBot.Mentions.Validator

  @bot_did "did:plc:contextbot"

  test "returns a receipt that preserves the raw eligible mention" do
    notification = mention_notification()

    assert {:ok, receipt} = Validator.validate(notification, @bot_did)
    assert receipt.uri == "at://did:plc:alice/app.bsky.feed.post/3kabc"
    assert receipt.cid == "bafyreialicepost"
    assert receipt.actor_did == "did:plc:alice"
    assert receipt.actor_handle == "alice.bsky.social"
    assert receipt.raw == notification
  end

  test "rejects notifications that are not mention notifications" do
    assert {:error, _reason} =
             Validator.validate(Map.put(mention_notification(), "reason", "reply"), @bot_did)
  end

  test "rejects records that are not Bluesky posts" do
    notification = put_in(mention_notification(), ["record", "$type"], "app.bsky.feed.like")

    assert {:error, _reason} = Validator.validate(notification, @bot_did)
  end

  test "rejects a self-authored post" do
    notification =
      mention_notification()
      |> put_in(["author", "did"], @bot_did)
      |> Map.put("uri", "at://#{@bot_did}/app.bsky.feed.post/3kabc")

    assert {:error, _reason} = Validator.validate(notification, @bot_did)
  end

  test "rejects a post URI outside the author repository" do
    notification =
      Map.put(mention_notification(), "uri", "at://did:plc:mallory/app.bsky.feed.post/3kabc")

    assert {:error, _reason} = Validator.validate(notification, @bot_did)
  end

  test "rejects a missing or empty CID" do
    assert {:error, _reason} =
             Validator.validate(Map.put(mention_notification(), "cid", ""), @bot_did)

    assert {:error, _reason} =
             Validator.validate(Map.delete(mention_notification(), "cid"), @bot_did)
  end

  test "rejects text-only handle matches without a mention facet" do
    notification = put_in(mention_notification(), ["record", "facets"], [])

    assert {:error, _reason} = Validator.validate(notification, @bot_did)
  end

  test "rejects a facet that mentions a different DID" do
    notification =
      put_in(
        mention_notification(),
        ["record", "facets", Access.at(0), "features", Access.at(0), "did"],
        "did:plc:someone-else"
      )

    assert {:error, _reason} = Validator.validate(notification, @bot_did)
  end

  defp mention_notification do
    %{
      "reason" => "mention",
      "uri" => "at://did:plc:alice/app.bsky.feed.post/3kabc",
      "cid" => "bafyreialicepost",
      "author" => %{"did" => "did:plc:alice", "handle" => "alice.bsky.social"},
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "text" => "Hi @context.bot, please add context.",
        "facets" => [
          %{
            "index" => %{"byteStart" => 3, "byteEnd" => 15},
            "features" => [
              %{"$type" => "app.bsky.richtext.facet#mention", "did" => @bot_did}
            ]
          }
        ]
      }
    }
  end
end
