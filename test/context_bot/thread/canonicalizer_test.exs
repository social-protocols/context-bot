defmodule ContextBot.Thread.CanonicalizerTest do
  use ExUnit.Case, async: true

  alias ContextBot.Thread.Canonicalizer

  @bot_did "did:plc:contextbot"
  @invocation_uri "at://did:plc:alice/app.bsky.feed.post/invocation"
  @notification_cid "bafy-invocation-v1"

  test "renders only the rootward parent chain in deterministic order" do
    thread = fixture("thread_ancestors.json")

    assert {:ok, result} = Canonicalizer.build(thread, context())

    assert result == %{
             version: 1,
             current_cid: "bafy-invocation-v1",
             parent: %{
               "uri" => @invocation_uri,
               "cid" => "bafy-invocation-v1"
             },
             root: %{
               "uri" => "at://did:plc:root/app.bsky.feed.post/root",
               "cid" => "bafy-root"
             },
             text:
               """
               CONTEXT_BOT_THREAD_V1

               [ancestor]
               Author: root.test (did:plc:root)
               URI: at://did:plc:root/app.bsky.feed.post/root
               Text:
               The root claim.
               External link: Evidence packet
               External URI: https://example.com/evidence

               [ancestor]
               Author: bob.test (did:plc:bob)
               URI: at://did:plc:bob/app.bsky.feed.post/parent
               Text:
               The immediate parent claim.
               Quoted post URI: at://did:plc:quoted/app.bsky.feed.post/quoted

               [invocation]
               Author: alice.test (did:plc:alice)
               URI: at://did:plc:alice/app.bsky.feed.post/invocation
               Text:
               @contextbot.test please add context.
               """
               |> String.trim()
           }

    refute result.text =~ "DESCENDANT"
    refute result.text =~ "QUOTED POST BODY"
    refute result.text =~ "MEDIA ALT"
    refute result.text =~ "EXTERNAL DESCRIPTION"
    refute result.text =~ "cdn.example"
  end

  test "marks a capped parent chain without changing the record's copied root" do
    assert {:ok, result} =
             Canonicalizer.build(fixture("thread_ancestors.json"), context(parent_height: 1))

    assert result.text =~ "[ancestor chain truncated]"
    assert result.text =~ "The immediate parent claim."
    assert result.text =~ "@contextbot.test please add context."
    refute result.text =~ "The root claim."

    assert result.root == %{
             "uri" => "at://did:plc:root/app.bsky.feed.post/root",
             "cid" => "bafy-root"
           }
  end

  test "renders blocked, unavailable, and unknown ancestor unions as explicit placeholders" do
    blocked = fixture("thread_blocked_parent.json")

    assert {:ok, blocked_result} = Canonicalizer.build(blocked, context())
    assert blocked_result.text =~ "[blocked ancestor]"

    unavailable =
      put_in(blocked, ["thread", "parent"], %{
        "$type" => "app.bsky.feed.defs#notFoundPost",
        "uri" => "at://did:plc:missing/app.bsky.feed.post/root",
        "notFound" => true
      })

    assert {:ok, unavailable_result} = Canonicalizer.build(unavailable, context())
    assert unavailable_result.text =~ "[unavailable ancestor]"

    unknown =
      put_in(blocked, ["thread", "parent"], %{
        "$type" => "app.bsky.feed.defs#futureAncestorVariant",
        "opaque" => %{"text" => "UNKNOWN UNION BODY MUST NEVER APPEAR"}
      })

    assert {:ok, unknown_result} = Canonicalizer.build(unknown, context())
    assert unknown_result.text =~ "[unknown ancestor]"
    refute unknown_result.text =~ "UNKNOWN UNION BODY"
  end

  test "treats an unavailable target as terminal" do
    for target <- [
          %{
            "$type" => "app.bsky.feed.defs#blockedPost",
            "uri" => @invocation_uri,
            "blocked" => true
          },
          %{
            "$type" => "app.bsky.feed.defs#notFoundPost",
            "uri" => @invocation_uri,
            "notFound" => true
          }
        ] do
      assert {:error, :target_unavailable} =
               Canonicalizer.build(%{"thread" => target}, context())
    end
  end

  test "freezes an edited current CID only while the current record still directly mentions the bot" do
    edited = fixture("thread_edited_cid.json")

    assert {:ok, result} = Canonicalizer.build(edited, context())
    assert result.current_cid == "bafy-invocation-v2"

    assert result.parent == %{
             "uri" => @invocation_uri,
             "cid" => "bafy-invocation-v2"
           }

    assert result.root == result.parent

    edited_away = put_in(edited, ["thread", "post", "record", "facets"], [])

    assert {:error, :target_unavailable} = Canonicalizer.build(edited_away, context())
  end

  test "rejects a fetched target with the wrong URI or malformed post data" do
    wrong_uri =
      put_in(
        fixture("thread_ancestors.json"),
        ["thread", "post", "uri"],
        "at://did:plc:mallory/app.bsky.feed.post/different"
      )

    assert {:error, :invalid_thread} = Canonicalizer.build(wrong_uri, context())
    assert {:error, :invalid_thread} = Canonicalizer.build(%{"thread" => %{}}, context())
    assert {:error, :invalid_thread} = Canonicalizer.build(%{}, context())
  end

  defp context(overrides \\ []) do
    %{
      bot_did: @bot_did,
      invocation_uri: @invocation_uri,
      notification_cid: @notification_cid,
      parent_height: 80
    }
    |> Map.merge(Map.new(overrides))
  end

  defp fixture(name) do
    "test/fixtures/atproto/#{name}"
    |> File.read!()
    |> Jason.decode!()
  end
end
