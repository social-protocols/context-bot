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
             version: 2,
             current_cid: "bafy-invocation-v1",
             media: [
               %{
                 "type" => "image",
                 "index" => 1,
                 "post_uri" => @invocation_uri,
                 "url" =>
                   "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:alice/bafkreiaurora@jpeg",
                 "alt" => "A pale aurora over dark mountains"
               }
             ],
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
               CONTEXT_BOT_THREAD_V2

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
               Images:
               - [image 1] Alt text: A pale aurora over dark mountains
               """
               |> String.trim()
           }

    refute result.text =~ "DESCENDANT"
    refute result.text =~ "QUOTED POST BODY"
    assert result.text =~ "[image 1] Alt text: A pale aurora over dark mountains"
    refute result.text =~ "EXTERNAL DESCRIPTION"
    refute result.text =~ "feed_fullsize"
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
    assert result.version == 2
    assert result.parent == %{"uri" => @invocation_uri, "cid" => @notification_cid}
    assert [%{"index" => 1, "post_uri" => @invocation_uri}] = result.media

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
    assert result.text =~ "A pale aurora over dark mountains"
  end

  test "numbers images root-to-invocation and recognizes record-with-media images" do
    thread = fixture("thread_ancestors.json")

    root_image = image_view("did:plc:root", "bafkreiroot", "Root image")
    target_image = get_in(thread, ["thread", "post", "embed"])
    quoted_record = get_in(thread, ["thread", "parent", "post", "embed"])

    thread =
      thread
      |> put_in(["thread", "parent", "parent", "post", "embed"], root_image)
      |> put_in(["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => quoted_record,
        "media" => target_image
      })

    assert {:ok, result} = Canonicalizer.build(thread, context())

    assert Enum.map(result.media, &{&1["index"], &1["post_uri"], &1["alt"]}) == [
             {1, "at://did:plc:root/app.bsky.feed.post/root", "Root image"},
             {2, @invocation_uri, "A pale aurora over dark mountains"}
           ]

    assert :binary.match(result.text, "[image 1]") < :binary.match(result.text, "[image 2]")
    assert result.text =~ "Quoted post URI: at://did:plc:quoted/app.bsky.feed.post/quoted"
    refute result.text =~ "QUOTED POST BODY"
  end

  test "recognizes gallery images directly and through record-with-media" do
    base = fixture("thread_ancestors.json")

    direct =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.gallery#view",
        "items" => [
          gallery_image("did:plc:alice", "bafkreigallery1", "Gallery one"),
          gallery_image("did:plc:alice", "bafkreigallery2", "Gallery two")
        ]
      })

    assert {:ok, direct_result} = Canonicalizer.build(direct, context())

    assert Enum.map(direct_result.media, &{&1["index"], &1["alt"]}) == [
             {1, "Gallery one"},
             {2, "Gallery two"}
           ]

    nested =
      put_in(direct, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => get_in(base, ["thread", "parent", "post", "embed"]),
        "media" => get_in(direct, ["thread", "post", "embed"])
      })

    assert {:ok, nested_result} = Canonicalizer.build(nested, context())
    assert Enum.map(nested_result.media, & &1["alt"]) == ["Gallery one", "Gallery two"]
    assert nested_result.text =~ "Quoted post URI: at://did:plc:quoted/app.bsky.feed.post/quoted"
  end

  test "accepts an external card inside record-with-media and fails closed on unknown embed unions" do
    base = fixture("thread_ancestors.json")
    quoted_record = get_in(base, ["thread", "parent", "post", "embed"])

    nested_external =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => quoted_record,
        "media" => %{
          "$type" => "app.bsky.embed.external#view",
          "external" => %{
            "title" => "Source card",
            "uri" => "https://example.com/source",
            "description" => "A source"
          }
        }
      })

    assert {:ok, result} = Canonicalizer.build(nested_external, context())
    assert result.media == []
    assert result.text =~ "External link: Source card"

    unknown_direct =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.futureMedia#view",
        "opaque" => %{"url" => "https://untrusted.example/media"}
      })

    assert {:error, :invalid_thread} = Canonicalizer.build(unknown_direct, context())

    unknown_nested =
      put_in(nested_external, ["thread", "post", "embed", "media"], %{
        "$type" => "app.bsky.embed.futureMedia#view"
      })

    assert {:error, :invalid_thread} = Canonicalizer.build(unknown_nested, context())

    unknown_gallery_item =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.gallery#view",
        "items" => [
          gallery_image("did:plc:alice", "bafkreifuture", "Future item")
          |> Map.put("$type", "app.bsky.embed.gallery#futureViewItem")
        ]
      })

    assert {:error, :invalid_thread} = Canonicalizer.build(unknown_gallery_item, context())
  end

  test "preserves direct and nested external cards whose valid title is empty" do
    base = fixture("thread_ancestors.json")

    empty_title_external = %{
      "$type" => "app.bsky.embed.external#view",
      "external" => %{
        "title" => "",
        "uri" => "https://example.com/untitled",
        "description" => "A valid card without a title"
      }
    }

    direct = put_in(base, ["thread", "post", "embed"], empty_title_external)
    assert {:ok, direct_result} = Canonicalizer.build(direct, context())
    assert direct_result.text =~ "External URI: https://example.com/untitled"
    refute direct_result.text =~ "External link: \nExternal URI: https://example.com/untitled"

    nested =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => get_in(base, ["thread", "parent", "post", "embed"]),
        "media" => empty_title_external
      })

    assert {:ok, nested_result} = Canonicalizer.build(nested, context())
    assert nested_result.text =~ "External URI: https://example.com/untitled"
    assert nested_result.text =~ "Quoted post URI: at://did:plc:quoted/app.bsky.feed.post/quoted"
  end

  test "rejects malformed or untrusted image descriptors" do
    base = fixture("thread_ancestors.json")

    invalid_images = [
      %{"alt" => "HTTP", "fullsize" => "http://cdn.bsky.app/img/feed_fullsize/plain/a/b@jpeg"},
      %{"alt" => "host", "fullsize" => "https://example.com/img/feed_fullsize/plain/a/b@jpeg"},
      %{
        "alt" => "userinfo",
        "fullsize" => "https://user@cdn.bsky.app/img/feed_fullsize/plain/a/b@jpeg"
      },
      %{
        "alt" => "fragment",
        "fullsize" => "https://cdn.bsky.app/img/feed_fullsize/plain/a/b@jpeg#fragment"
      },
      %{
        "alt" => "port",
        "fullsize" => "https://cdn.bsky.app:444/img/feed_fullsize/plain/a/b@jpeg"
      },
      %{"alt" => "missing"},
      %{
        "alt" => "long URL",
        "fullsize" =>
          "https://cdn.bsky.app/img/feed_fullsize/plain/a/#{String.duplicate("x", 2_048)}@jpeg"
      },
      %{
        "alt" => String.duplicate("x", 4_097),
        "fullsize" => "https://cdn.bsky.app/img/feed_fullsize/plain/a/b@jpeg"
      }
    ]

    Enum.each(invalid_images, fn image ->
      thread = put_in(base, ["thread", "post", "embed", "images"], [image])
      assert {:error, :invalid_thread} = Canonicalizer.build(thread, context())
    end)
  end

  test "detects video directly and through record-with-media" do
    direct = fixture("thread_video.json")

    assert {:unsupported_media, %{reason: :video, canonical: direct_result}} =
             Canonicalizer.build(direct, context())

    assert direct_result.version == 2
    assert direct_result.media == []

    nested =
      put_in(direct, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => %{
          "$type" => "app.bsky.embed.record#view",
          "record" => %{
            "uri" => "at://did:plc:quoted/app.bsky.feed.post/quoted"
          }
        },
        "media" => get_in(direct, ["thread", "post", "embed"])
      })

    assert {:unsupported_media, %{reason: :video}} =
             Canonicalizer.build_dry_run(nested, dry_run_context())
  end

  test "fails closed above four images and gives video precedence" do
    base = fixture("thread_ancestors.json")

    five_images =
      Enum.map(1..5, fn index ->
        gallery_image("did:plc:alice", "bafkrei#{index}", "Image #{index}")
      end)

    over_limit =
      put_in(base, ["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.gallery#view",
        "items" => five_images
      })

    assert {:unsupported_media, %{reason: :image_limit_exceeded, canonical: %{media: media}}} =
             Canonicalizer.build(over_limit, context())

    assert length(media) == 4

    with_video =
      put_in(
        over_limit,
        ["thread", "parent", "parent", "post", "embed"],
        get_in(fixture("thread_video.json"), ["thread", "post", "embed"])
      )

    assert {:unsupported_media, %{reason: :video}} =
             Canonicalizer.build(with_video, context())
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

  defp image_view(did, cid, alt) do
    %{
      "$type" => "app.bsky.embed.images#view",
      "images" => [
        %{
          "alt" => alt,
          "fullsize" => "https://cdn.bsky.app/img/feed_fullsize/plain/#{did}/#{cid}@jpeg"
        }
      ]
    }
  end

  defp gallery_image(did, cid, alt) do
    %{
      "$type" => "app.bsky.embed.gallery#viewImage",
      "alt" => alt,
      "aspectRatio" => %{"height" => 1, "width" => 1},
      "fullsize" => "https://cdn.bsky.app/img/feed_fullsize/plain/#{did}/#{cid}@jpeg",
      "thumbnail" => "https://cdn.bsky.app/img/feed_thumbnail/plain/#{did}/#{cid}@jpeg"
    }
  end

  defp safely_build(response) do
    Canonicalizer.build(response, context())
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    kind, reason -> {kind, reason}
  end
end
