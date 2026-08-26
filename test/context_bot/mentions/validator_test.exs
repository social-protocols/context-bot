defmodule ContextBot.Mentions.ValidatorTest do
  use ExUnit.Case, async: true

  alias ContextBot.Mentions.Validator

  @bot_did "did:plc:contextbot"
  @raw_notification_max_bytes 65_536

  test "returns a receipt that preserves the raw eligible mention" do
    notification = mention_notification()

    assert {:ok, receipt} = Validator.validate(notification, @bot_did)
    assert receipt.uri == "at://did:plc:alice/app.bsky.feed.post/3kabc"
    assert receipt.cid == "bafyreialicepost"
    assert receipt.actor_did == "did:plc:alice"
    assert receipt.actor_handle == "alice.bsky.social"
    assert receipt.raw == notification
  end

  test "accepts a reply to a bot post as an invocation even without a mention facet" do
    notification = reply_notification(@bot_did)

    assert {:ok, receipt} = Validator.validate(notification, @bot_did)
    assert receipt.uri == "at://did:plc:alice/app.bsky.feed.post/3kreply"
    assert receipt.cid == "bafyreiareply"
    assert receipt.actor_did == "did:plc:alice"
    assert receipt.actor_handle == "alice.bsky.social"
    assert receipt.raw == notification
  end

  test "rejects a reply whose parent is not authored by the bot" do
    assert {:error, :parent_not_by_bot} =
             Validator.validate(reply_notification("did:plc:bob"), @bot_did)
  end

  test "rejects a reply with an invalid parent URI" do
    notification =
      put_in(reply_notification(@bot_did), ["record", "reply", "parent", "uri"], "not-an-at-uri")

    assert {:error, :invalid_reply_parent} = Validator.validate(notification, @bot_did)
  end

  test "rejects a bot replying to itself" do
    notification =
      reply_notification(@bot_did)
      |> put_in(["author", "did"], @bot_did)
      |> Map.put("uri", "at://#{@bot_did}/app.bsky.feed.post/3kreply")

    assert {:error, :invalid_author} = Validator.validate(notification, @bot_did)
  end

  test "rejects a reply without a reply parent field" do
    notification =
      reply_notification(@bot_did)
      |> put_in(["record"], %{
        "$type" => "app.bsky.feed.post",
        "text" => "This is just a regular post"
      })

    assert {:error, :missing_reply_parent} = Validator.validate(notification, @bot_did)
  end

  test "rejects notifications that are not mention or reply notifications" do
    assert {:error, _reason} =
             Validator.validate(Map.put(mention_notification(), "reason", "like"), @bot_did)
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

  test "rejects a post-typed record whose URI names a different collection" do
    notification =
      Map.put(
        mention_notification(),
        "uri",
        "at://did:plc:alice/app.bsky.feed.like/3kabc"
      )

    assert {:error, :invalid_post_uri} = Validator.validate(notification, @bot_did)
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

  test "accepts a raw notification at the configured JSON byte boundary" do
    notification = notification_at_json_size(@raw_notification_max_bytes)

    assert byte_size(Jason.encode!(notification)) == @raw_notification_max_bytes
    assert {:ok, %{raw: ^notification}} = Validator.validate(notification, @bot_did)
  end

  test "rejects a semantically valid raw notification one byte beyond the JSON byte boundary" do
    notification = notification_at_json_size(@raw_notification_max_bytes + 1)

    assert byte_size(Jason.encode!(notification)) == @raw_notification_max_bytes + 1
    assert {:error, :raw_notification_too_large} = Validator.validate(notification, @bot_did)
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

  defp reply_notification(parent_did) do
    %{
      "reason" => "reply",
      "uri" => "at://did:plc:alice/app.bsky.feed.post/3kreply",
      "cid" => "bafyreiareply",
      "author" => %{"did" => "did:plc:alice", "handle" => "alice.bsky.social"},
      "record" => %{
        "$type" => "app.bsky.feed.post",
        "text" => "Thanks for the context!",
        "reply" => %{
          "parent" => %{
            "uri" => "at://#{parent_did}/app.bsky.feed.post/3kbotpost",
            "cid" => "bafyreibotpost"
          },
          "root" => %{
            "uri" => "at://did:plc:bob/app.bsky.feed.post/3kroot",
            "cid" => "bafyreiroot"
          }
        }
      }
    }
  end

  defp notification_at_json_size(size) do
    notification = Map.put(mention_notification(), "padding", "")
    padding_size = size - byte_size(Jason.encode!(notification))
    Map.put(notification, "padding", String.duplicate("x", padding_size))
  end
end
