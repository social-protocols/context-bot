defmodule ContextBot.Reply.FollowerPostTest do
  use ExUnit.Case, async: true

  alias ContextBot.Reply.FollowerPost
  alias ContextBot.Workflow.Invocation

  @created_at ~U[2026-09-04 22:46:35.681Z]
  @root_uri "at://did:plc:6iskodvunf6hre4lki5vi3pu/app.bsky.feed.post/3mupojjkq4k2n"
  @root_cid "bafyreic4zronyigsv3tjjxdnee2qmzbmcducbhxrfe75jq6gsry3zeicdq"
  @invocation_uri "at://did:plc:asker/app.bsky.feed.post/3muqinvok3abc"
  @reply_uri "at://did:plc:anbhmngzs3exwbq47xxzogk4/app.bsky.feed.post/3muqreply1abc"
  @reader_url "https://standard-reader.app/a/did:plc:anbhmngzs3exwbq47xxzogk4/3mupz2v6j6h3u"
  @mirror_url_id 33
  @asked "@getcontext.bot Is there evidence the FDA cuts are causing Americans to get sicker?"
  @title "FDA cuts and rising illness: what's verified"

  test "builds a top-level quote of the parent root with a Reader external card" do
    invocation = invocation()

    assert {:ok, record} = FollowerPost.build(invocation, @created_at)

    refute Map.has_key?(record, "reply")
    assert record["$type"] == "app.bsky.feed.post"
    assert record["text"] == "standard-reader.app/a/did:plc:an..."
    assert record["createdAt"] == "2026-09-04T22:46:35.681Z"

    assert [facet] = record["facets"]
    assert facet["index"] == %{"byteStart" => 0, "byteEnd" => byte_size(record["text"])}

    assert hd(facet["features"]) == %{
             "$type" => "app.bsky.richtext.facet#link",
             "uri" => @reader_url
           }

    assert record["embed"]["$type"] == "app.bsky.embed.recordWithMedia"

    assert record["embed"]["record"] == %{
             "$type" => "app.bsky.embed.record",
             "record" => %{"uri" => @root_uri, "cid" => @root_cid}
           }

    assert record["embed"]["media"] == %{
             "$type" => "app.bsky.embed.external",
             "external" => %{
               "uri" => @reader_url,
               "title" => @title <> " · Context Bot",
               "description" => @asked
             }
           }
  end

  test "does not quote the invoking mention or the bot reply" do
    invocation =
      invocation(%{
        reply_uri: @reply_uri,
        reply_cid: "bafy-bot-reply",
        invocation_uri: @invocation_uri
      })

    assert {:ok, record} = FollowerPost.build(invocation, @created_at)

    quoted = record["embed"]["record"]["record"]["uri"]
    assert quoted == @root_uri
    refute quoted == @invocation_uri
    refute quoted == @reply_uri
  end

  test "uses a short getcontext.bot mirror URL when that is the published link" do
    mirror = "https://getcontext.bot/r/#{@mirror_url_id}"

    invocation =
      invocation(%{
        id: @mirror_url_id,
        reply_record: linked_reply(mirror),
        standard_site_document_uri:
          "at://did:plc:anbhmngzs3exwbq47xxzogk4/site.standard.document/3mupz2v6j6h3u"
      })

    assert {:ok, record} = FollowerPost.build(invocation, @created_at)
    assert record["text"] == "getcontext.bot/r/#{@mirror_url_id}"
    assert hd(hd(record["facets"])["features"])["uri"] == mirror
    assert record["embed"]["media"]["external"]["uri"] == mirror
  end

  test "skips when the thread has no quoteable parent root" do
    assert FollowerPost.eligible?(invocation(%{root_uri: nil, root_cid: nil})) == false
    assert {:error, :ineligible} = FollowerPost.build(invocation(%{root_uri: nil}), @created_at)

    same_as_mention =
      invocation(%{root_uri: @invocation_uri, root_cid: "bafy-mention"})

    assert FollowerPost.eligible?(same_as_mention) == false
    assert {:error, :ineligible} = FollowerPost.build(same_as_mention, @created_at)
  end

  test "skips no_reply, dry_run, and a missing full-response URL" do
    assert FollowerPost.eligible?(invocation(%{no_reply: true})) == false
    assert {:error, :ineligible} = FollowerPost.build(invocation(%{no_reply: true}), @created_at)

    assert FollowerPost.eligible?(invocation(%{dry_run: true})) == false

    unlinked =
      invocation(%{
        reply_record: %{"text" => "Compact only."},
        standard_site_document_uri: nil
      })

    assert FollowerPost.eligible?(unlinked) == false
    assert {:error, :ineligible} = FollowerPost.build(unlinked, @created_at)
  end

  defp invocation(overrides \\ %{}) do
    struct!(
      Invocation,
      Map.merge(
        %{
          id: 33,
          dry_run: false,
          no_reply: false,
          invocation_uri: @invocation_uri,
          current_cid: "bafy-invocation",
          root_uri: @root_uri,
          root_cid: @root_cid,
          selected_reply: "Americans are getting sicker, but the FDA-cut link is unverified.",
          reply_validation: %{"document_title" => @title},
          raw_notification: %{"record" => %{"text" => @asked}},
          reply_record: linked_reply(@reader_url),
          standard_site_document_uri:
            "at://did:plc:anbhmngzs3exwbq47xxzogk4/site.standard.document/3mupz2v6j6h3u"
        },
        overrides
      )
    )
  end

  defp linked_reply(url) do
    %{
      "$type" => "app.bsky.feed.post",
      "text" => "Compact (full response)",
      "facets" => [
        %{
          "index" => %{"byteStart" => 8, "byteEnd" => 21},
          "features" => [%{"$type" => "app.bsky.richtext.facet#link", "uri" => url}]
        }
      ]
    }
  end
end
