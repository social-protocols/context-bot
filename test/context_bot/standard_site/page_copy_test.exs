defmodule ContextBot.StandardSite.PageCopyTest do
  use ExUnit.Case, async: true

  alias ContextBot.StandardSite.PageCopy

  @bot_did "did:plc:contextbot"
  @bot_handle "getcontext.bot"
  @invocation_uri "at://did:plc:alice/app.bsky.feed.post/3muajo3wxyz"
  @parent_uri "at://did:plc:bob/app.bsky.feed.post/3parentrkey12"

  describe "strip_bot_mentions/4" do
    test "removes the public @getcontext.bot handle and configured handle" do
      assert PageCopy.strip_bot_mentions(
               "@getcontext.bot What bird is that?",
               %{},
               @bot_did,
               @bot_handle
             ) == "What bird is that?"

      assert PageCopy.strip_bot_mentions(
               "hey @contextbot.test is this planned?",
               %{},
               @bot_did,
               "contextbot.test"
             ) == "hey is this planned?"
    end

    test "removes every bot mention by UTF-8 facet byte offsets" do
      text = "¿Por qué? @getcontext.bot y @getcontext.bot"
      first_start = byte_size("¿Por qué? ")
      first_end = first_start + byte_size("@getcontext.bot")
      second_start = first_end + byte_size(" y ")
      second_end = second_start + byte_size("@getcontext.bot")

      record = %{
        "text" => text,
        "facets" => [
          mention_facet(first_start, first_end, @bot_did),
          mention_facet(second_start, second_end, @bot_did)
        ]
      }

      assert PageCopy.strip_bot_mentions(text, record, @bot_did, @bot_handle) == "¿Por qué? y"
    end

    test "leaves other accounts' mentions in place" do
      text = "@alice.test @getcontext.bot what happened?"

      assert PageCopy.strip_bot_mentions(text, %{}, @bot_did, @bot_handle) ==
               "@alice.test what happened?"
    end

    test "does not fail when facets are missing or unusable" do
      assert PageCopy.strip_bot_mentions(
               "@getcontext.bot Planned explosion?",
               %{"facets" => "nope"},
               @bot_did,
               nil
             ) == "Planned explosion?"
    end
  end

  describe "title/1" do
    test "uses a usable model headline of the question" do
      assert PageCopy.title(%{
               asked_text: "hey can you identify this bird in the photo",
               document_title: "What bird is that?",
               selected_reply: "That's a Himalayan Monal in breeding plumage."
             }) == "What bird is that?"
    end

    test "falls back to short stripped invocation text and strips a trailing period" do
      assert PageCopy.title(%{
               asked_text: "Planned explosion.",
               document_title: nil,
               selected_reply: "No, that was a controlled demolition."
             }) == "Planned explosion"
    end

    test "tightly truncates a long stripped question instead of using the rkey TID" do
      asked =
        "Can you help me understand the historical context of this planned explosion near the harbor?"

      title =
        PageCopy.title(%{
          asked_text: asked,
          invocation_uri: @invocation_uri,
          document_title: nil,
          selected_reply: "The blast was a planned demolition."
        })

      assert title == "Can you help me understand the"
      refute title =~ "3muajo3w"
      refute title =~ "Context on"
    end

    test "discards junk model titles and never falls back to the invocation TID" do
      asked = "What bird is that?"
      reply = "That's a Himalayan Monal in breeding plumage on a Himalayan ridge."

      for junk <- [nil, "", "   ", "Context on 3muajo3w...", "3muajo3wxyz", reply] do
        assert PageCopy.title(%{
                 asked_text: asked,
                 invocation_uri: @invocation_uri,
                 document_title: junk,
                 selected_reply: reply
               }) == "What bird is that?"
      end

      long_junk = String.duplicate("word ", 40) |> String.trim()

      assert PageCopy.title(%{
               asked_text: asked,
               invocation_uri: @invocation_uri,
               document_title: long_junk,
               selected_reply: reply
             }) == "What bird is that?"
    end

    test "uses a generic headline when no question text remains" do
      title =
        PageCopy.title(%{
          asked_text: "",
          invocation_uri: @invocation_uri,
          document_title: "Context on 3muajo3w...",
          selected_reply: "That's a Himalayan Monal."
        })

      assert title == "Context request"
      refute title =~ "3muajo3w"
      refute title =~ "Context on"
    end
  end

  describe "description/1" do
    test "uses the stripped invocation text rather than the Bluesky reply" do
      assert PageCopy.description(%{
               asked_text: "What bird is that?",
               selected_reply: "That's a Himalayan Monal in breeding plumage."
             }) == "What bird is that?"
    end

    test "truncates only when the stripped text exceeds the card grapheme cap" do
      asked = String.duplicate("字", PageCopy.description_max_graphemes() + 20)

      description = PageCopy.description(%{asked_text: asked, selected_reply: "unused"})

      assert String.length(description) == PageCopy.description_max_graphemes()
      assert String.starts_with?(asked, description)
    end

    test "returns nil when there is no stripped invocation text" do
      assert PageCopy.description(%{asked_text: "", selected_reply: "That's a Himalayan Monal."}) ==
               nil
    end
  end

  describe "asked_markdown/1" do
    test "renders the stripped invocation and a public Bluesky link" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: "What bird is that?",
          invocation_uri: @invocation_uri
        })

      assert markdown =~ "## Asked"
      assert markdown =~ "What bird is that?"
      assert markdown =~ "https://bsky.app/profile/did:plc:alice/post/3muajo3wxyz"
      refute markdown =~ "Parent post"
    end

    test "adds a parent link when the invoking post is a reply" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: "What bird is that?",
          invocation_uri: @invocation_uri,
          parent_uri: @parent_uri
        })

      assert markdown =~ "https://bsky.app/profile/did:plc:alice/post/3muajo3wxyz"
      assert markdown =~ "https://bsky.app/profile/did:plc:bob/post/3parentrkey12"
    end

    test "omits the parent link when the parent URI is missing or unusable" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: "What bird is that?",
          invocation_uri: @invocation_uri,
          parent_uri: "not-an-at-uri"
        })

      refute markdown =~ "Parent"
      refute markdown =~ "not-an-at-uri"
    end
  end

  describe "subject/2" do
    test "prefers the thread target record, strips the mention, and keeps the parent URI" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_notification: %{"uri" => @invocation_uri},
        raw_thread: %{
          "thread" => %{
            "post" => %{
              "uri" => @invocation_uri,
              "record" => %{
                "text" => "@getcontext.bot What bird is that?",
                "facets" => [mention_facet(0, 15, @bot_did)],
                "reply" => %{"parent" => %{"uri" => @parent_uri}}
              }
            }
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "What bird is that?"
      assert subject.parent_uri == @parent_uri
      assert subject.invocation_uri == @invocation_uri
    end

    test "falls back to the notification record and omits a missing parent" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{
          "record" => %{
            "text" => "@getcontext.bot Planned explosion?",
            "facets" => [mention_facet(0, 15, @bot_did)]
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "Planned explosion?"
      assert subject.parent_uri == nil
    end

    test "uses live-run invocation_text when no post record is present" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: "Is this fair?",
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{"source" => "local_live_demo"}
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "Is this fair?"
      assert subject.parent_uri == nil
    end

    test "does not invent a parent when the record has no reply" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{
          "post" => %{
            "record" => %{"text" => "@getcontext.bot What bird is that?"}
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "What bird is that?"
      assert subject.parent_uri == nil
    end
  end

  defp mention_facet(first, last, did) do
    %{
      "index" => %{"byteStart" => first, "byteEnd" => last},
      "features" => [
        %{"$type" => "app.bsky.richtext.facet#mention", "did" => did}
      ]
    }
  end
end
