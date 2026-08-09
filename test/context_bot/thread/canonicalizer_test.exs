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

  test "renders a dry-run question beneath the selected post without requiring a mention" do
    thread = fixture("thread_ancestors.json")

    assert {:ok, result} =
             Canonicalizer.build_dry_run(thread, %{
               target_uri: @invocation_uri,
               invocation_text: "Is this fair?",
               parent_height: 80
             })

    assert result.current_cid == @notification_cid
    assert result.parent == %{"uri" => @invocation_uri, "cid" => @notification_cid}

    assert result.root == %{
             "uri" => "at://did:plc:root/app.bsky.feed.post/root",
             "cid" => "bafy-root"
           }

    assert result.text =~ "The root claim."
    assert result.text =~ "The immediate parent claim."
    assert result.text =~ "[target]\n"
    assert result.text =~ "@contextbot.test please add context."
    assert result.text =~ "[invocation]\nText:\nIs this fair?"

    assert :binary.match(result.text, "The root claim.") <
             :binary.match(result.text, "The immediate parent claim.")

    assert :binary.match(result.text, "The immediate parent claim.") <
             :binary.match(result.text, "[target]")

    assert :binary.match(result.text, "[target]") <
             :binary.match(result.text, "[invocation]")

    refute result.text =~ "DESCENDANT"
    refute result.text =~ "QUOTED POST BODY"
    refute result.text =~ "MEDIA ALT"
  end

  test "dry-run canonicalization preserves ancestor placeholders and truncation" do
    blocked = fixture("thread_blocked_parent.json")

    assert {:ok, blocked_result} =
             Canonicalizer.build_dry_run(blocked, dry_run_context())

    assert blocked_result.text =~ "[blocked ancestor]"

    server_capped =
      update_in(
        fixture("thread_ancestors.json"),
        ["thread", "parent"],
        &Map.delete(&1, "parent")
      )

    assert {:ok, capped_result} =
             Canonicalizer.build_dry_run(server_capped, dry_run_context(parent_height: 1))

    assert capped_result.text =~ "[ancestor chain truncated]"
    assert capped_result.text =~ "[invocation]\nText:\nWhat's missing?"
  end

  test "dry-run canonicalization rejects unavailable, wrong, and malformed targets" do
    unavailable = %{
      "thread" => %{
        "$type" => "app.bsky.feed.defs#notFoundPost",
        "uri" => @invocation_uri,
        "notFound" => true
      }
    }

    assert {:error, :target_unavailable} =
             Canonicalizer.build_dry_run(unavailable, dry_run_context())

    wrong =
      put_in(
        fixture("thread_ancestors.json"),
        ["thread", "post", "uri"],
        "at://did:plc:mallory/app.bsky.feed.post/different"
      )

    assert {:error, :invalid_thread} = Canonicalizer.build_dry_run(wrong, dry_run_context())
    assert {:error, :invalid_thread} = Canonicalizer.build_dry_run(%{}, dry_run_context())
  end

  test "marks a server-capped chain when the deepest returned ancestor is not the record root" do
    server_capped =
      update_in(
        fixture("thread_ancestors.json"),
        ["thread", "parent"],
        &Map.delete(&1, "parent")
      )

    assert {:ok, result} =
             Canonicalizer.build(server_capped, context(parent_height: 1))

    assert result.text =~ "[ancestor chain truncated]"
    assert result.text =~ "The immediate parent claim."
    assert result.text =~ "@contextbot.test please add context."
    refute result.text =~ "The root claim."

    assert result.root == %{
             "uri" => "at://did:plc:root/app.bsky.feed.post/root",
             "cid" => "bafy-root"
           }
  end

  test "does not mark truncation when the deepest returned ancestor is the record root" do
    full_thread = fixture("thread_ancestors.json")
    root_view = get_in(full_thread, ["thread", "parent", "parent"])
    root_ref = get_in(full_thread, ["thread", "post", "record", "reply", "root"])

    root_complete =
      full_thread
      |> put_in(["thread", "parent"], root_view)
      |> put_in(["thread", "post", "record", "reply", "parent"], root_ref)

    assert {:ok, result} = Canonicalizer.build(root_complete, context(parent_height: 1))
    refute result.text =~ "[ancestor chain truncated]"
    assert result.text =~ "The root claim."
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

  test "returns invalid_thread without raising for malformed target records and roots" do
    base = fixture("thread_ancestors.json")

    malformed = [
      put_in(base, ["thread", "post", "record", "reply"], "not-a-map"),
      put_in(base, ["thread", "post", "record", "reply"], ["not-a-map"]),
      put_in(base, ["thread", "post", "record", "reply", "root"], "not-a-ref"),
      put_in(base, ["thread", "post", "record", "reply", "root", "cid"], ""),
      put_in(base, ["thread", "post"], "not-a-post")
    ]

    Enum.each(malformed, fn response ->
      assert safely_build(response) == {:error, :invalid_thread}
    end)
  end

  test "rejects target URI, CID, or author fields inconsistent with the invocation" do
    base = fixture("thread_ancestors.json")

    invalid_targets = [
      put_in(
        base,
        ["thread", "post", "uri"],
        "at://did:plc:mallory/app.bsky.feed.post/different"
      ),
      put_in(base, ["thread", "post", "cid"], ""),
      put_in(base, ["thread", "post", "author", "did"], "did:plc:mallory")
    ]

    Enum.each(invalid_targets, fn response ->
      assert safely_build(response) == {:error, :invalid_thread}
    end)
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

  defp dry_run_context(overrides \\ []) do
    %{
      target_uri: @invocation_uri,
      invocation_text: "What's missing?",
      parent_height: 80
    }
    |> Map.merge(Map.new(overrides))
  end

  defp fixture(name) do
    "test/fixtures/atproto/#{name}"
    |> File.read!()
    |> Jason.decode!()
  end

  defp safely_build(response) do
    Canonicalizer.build(response, context())
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, reason -> {kind, reason}
  end
end
