defmodule ContextBot.StandardSite.PageCopyTest do
  use ExUnit.Case, async: true

  alias ContextBot.StandardSite.PageCopy
  alias ContextBot.StandardSite.TitlePrompt

  @bot_did "did:plc:contextbot"
  @bot_handle "getcontext.bot"
  @invocation_uri "at://did:plc:alice/app.bsky.feed.post/3muajo3wxyz"
  @parent_uri "at://did:plc:bob/app.bsky.feed.post/3parentrkey12"

  @launch_invocation """
                     I have just launched @getcontext.bot. Mention it in a post or reply and get a response from Claude. @getcontext.bot, say hello!
                     """
                     |> String.trim()

  @bird_invocation "@getcontext.bot what bird is that?"

  describe "title/1" do
    test "uses a Title Case model headline such as Context Bot Launch" do
      assert PageCopy.title(%{
               asked_text: @launch_invocation,
               document_title: "Context Bot Launch",
               selected_reply: "Hello! I'm @getcontext.bot — mention me in a thread."
             }) == "Context Bot Launch"
    end

    test "uses What Is That Bird? rather than a mention-stripped remnant" do
      assert PageCopy.title(%{
               asked_text: @bird_invocation,
               document_title: "What Is That Bird?",
               selected_reply: "That's a Himalayan Monal in breeding plumage."
             }) == "What Is That Bird?"
    end

    test "does not turn the launch invocation into a six-word remnant" do
      title =
        PageCopy.title(%{
          asked_text: @launch_invocation,
          document_title: nil,
          selected_reply: "Hello! I'm @getcontext.bot."
        })

      refute title == "I have just launched. Mention."
      refute title == "I have just launched . Mention"
      refute title =~ "launched ."
      refute title =~ ", say hello"
      assert title =~ "@getcontext.bot" or title == "Context request"
    end

    test "falls back to the first raw sentence and keeps mentions" do
      assert PageCopy.title(%{
               asked_text: "Planned explosion.",
               document_title: nil,
               selected_reply: "No, that was a controlled demolition."
             }) == "Planned explosion"

      assert PageCopy.title(%{
               asked_text: @bird_invocation,
               document_title: nil,
               selected_reply: "That's a Himalayan Monal in breeding plumage."
             }) == @bird_invocation
    end

    test "does not use a six-word slice of a long question as the title" do
      asked =
        "Can you help me understand the historical context of this planned explosion near the harbor?"

      title =
        PageCopy.title(%{
          asked_text: asked,
          invocation_uri: @invocation_uri,
          document_title: nil,
          selected_reply: "The blast was a planned demolition."
        })

      refute title == "Can you help me understand the"
      refute title =~ "3muajo3w"
      refute title =~ "Context on"
      assert String.starts_with?(asked, title)
      assert String.contains?(title, "historical") or String.length(title) > 40
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
    test "keeps the launch invocation intact, including @getcontext.bot" do
      assert PageCopy.description(%{
               asked_text: @launch_invocation,
               selected_reply: "Hello! I'm @getcontext.bot."
             }) == @launch_invocation

      description =
        PageCopy.description(%{
          asked_text: @launch_invocation,
          selected_reply: "Hello! I'm @getcontext.bot."
        })

      assert description =~ "@getcontext.bot"
      refute description =~ "launched ."
      refute description =~ "Claude. , say"
    end

    test "keeps @getcontext.bot what bird is that? as written" do
      assert PageCopy.description(%{
               asked_text: @bird_invocation,
               selected_reply: "That's a Himalayan Monal in breeding plumage."
             }) == @bird_invocation
    end

    test "truncates only when the raw text exceeds the card grapheme cap" do
      asked = String.duplicate("字", PageCopy.description_max_graphemes() + 20)

      description = PageCopy.description(%{asked_text: asked, selected_reply: "unused"})

      assert String.length(description) == PageCopy.description_max_graphemes()
      assert String.starts_with?(asked, description)
    end

    test "returns nil when there is no invocation text" do
      assert PageCopy.description(%{asked_text: "", selected_reply: "That's a Himalayan Monal."}) ==
               nil
    end
  end

  describe "asked_markdown/1" do
    test "renders a root responding-to line with handle post URLs and no invocation text" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: @launch_invocation,
          invocation_uri: @invocation_uri,
          invoker_handle: "jonathanwarden.com"
        })

      assert markdown ==
               "Responding to [@jonathanwarden.com](https://bsky.app/profile/jonathanwarden.com/post/3muajo3wxyz)'s post."

      refute markdown =~ "## Asked"
      refute markdown =~ @launch_invocation
      refute markdown =~ "Invoking post"
    end

    test "renders a reply responding-to line with invoker and parent handle post URLs" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: @bird_invocation,
          invocation_uri: @invocation_uri,
          parent_uri: @parent_uri,
          invoker_handle: "jonathanwarden.com",
          parent_handle: "moultano.bsky.social"
        })

      assert markdown ==
               "Responding to [@jonathanwarden.com](https://bsky.app/profile/jonathanwarden.com/post/3muajo3wxyz)'s reply to [@moultano.bsky.social](https://bsky.app/profile/moultano.bsky.social/post/3parentrkey12)'s post."

      refute markdown =~ "## Asked"
      refute markdown =~ @bird_invocation
    end

    test "falls back to the AT-URI repo when a handle is missing" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: @bird_invocation,
          invocation_uri: @invocation_uri,
          parent_uri: @parent_uri
        })

      assert markdown ==
               "Responding to [@did:plc:alice](https://bsky.app/profile/did:plc:alice/post/3muajo3wxyz)'s reply to [@did:plc:bob](https://bsky.app/profile/did:plc:bob/post/3parentrkey12)'s post."
    end

    test "uses the root sentence when the parent URI is missing or unusable" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: @bird_invocation,
          invocation_uri: @invocation_uri,
          parent_uri: "not-an-at-uri",
          invoker_handle: "alice.test"
        })

      assert markdown ==
               "Responding to [@alice.test](https://bsky.app/profile/alice.test/post/3muajo3wxyz)'s post."

      refute markdown =~ "Parent"
      refute markdown =~ "not-an-at-uri"
      refute markdown =~ @bird_invocation
    end

    test "does not fail when the invocation URI is missing" do
      markdown =
        PageCopy.asked_markdown(%{
          asked_text: @bird_invocation,
          invoker_handle: "alice.test"
        })

      assert is_binary(markdown)
      refute markdown =~ "## Asked"
      refute markdown =~ @bird_invocation
    end
  end

  describe "subject/2" do
    test "prefers the thread target record, keeps mentions, and keeps the parent URI" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_notification: %{"uri" => @invocation_uri},
        raw_thread: %{
          "thread" => %{
            "post" => %{
              "uri" => @invocation_uri,
              "author" => %{"did" => "did:plc:alice", "handle" => "alice.test"},
              "record" => %{
                "text" => @bird_invocation,
                "facets" => [mention_facet(0, 15, @bot_did)],
                "reply" => %{"parent" => %{"uri" => @parent_uri}}
              }
            },
            "parent" => %{
              "post" => %{
                "uri" => @parent_uri,
                "author" => %{"did" => "did:plc:bob", "handle" => "bob.test"}
              }
            }
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == @bird_invocation
      assert subject.parent_uri == @parent_uri
      assert subject.invocation_uri == @invocation_uri
      assert subject.invoker_handle == "alice.test"
      assert subject.parent_handle == "bob.test"
    end

    test "falls back to the notification record and omits a missing parent" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{
          "author" => %{"did" => "did:plc:alice", "handle" => "alice.test"},
          "record" => %{
            "text" => "@getcontext.bot Planned explosion?",
            "facets" => [mention_facet(0, 15, @bot_did)]
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "@getcontext.bot Planned explosion?"
      assert subject.parent_uri == nil
      assert subject.invoker_handle == "alice.test"
      assert subject.parent_handle == nil
    end

    test "uses live-run invocation_text when no post record is present" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: "Is this fair?",
        actor_handle: "operator.test",
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{"source" => "local_live_demo"}
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == "Is this fair?"
      assert subject.parent_uri == nil
      assert subject.invoker_handle == "operator.test"
      assert subject.parent_handle == nil
    end

    test "does not invent a parent when the record has no reply" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{
          "post" => %{
            "record" => %{"text" => @bird_invocation}
          }
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == @bird_invocation
      assert subject.parent_uri == nil
    end

    test "keeps the launch invocation text as written" do
      invocation = %{
        invocation_uri: @invocation_uri,
        invocation_text: nil,
        canonical_thread: nil,
        raw_thread: nil,
        raw_notification: %{
          "record" => %{"text" => @launch_invocation}
        }
      }

      subject = PageCopy.subject(invocation, %{bot_did: @bot_did, bot_handle: @bot_handle})

      assert subject.asked_text == @launch_invocation
    end
  end

  describe "TitlePrompt" do
    test "is Reader title wording for the research schema and the title-only rewrite call" do
      prompt = TitlePrompt.prompt()
      description = TitlePrompt.schema_description()

      assert TitlePrompt.id() == "READER_TITLE_V1"
      assert String.starts_with?(prompt, "READER_TITLE_V1")
      assert prompt =~ "Title Case"
      assert prompt =~ "Context Bot Launch"
      assert prompt =~ "What Is That Bird?"
      assert prompt =~ "The Story on the Yosemite Land Deal"
      assert prompt =~ "'The Range of Acceptable Opinion' on Bluesky"
      assert prompt =~ "first six words"
      assert description =~ "What Is That Bird?"
      assert description =~ "80 Unicode grapheme"
      refute prompt =~ "CONTEXT_BOT_SYSTEM"
      refute prompt =~ "---COMPACT_REPLY---"
    end

    test "asks for a title from the raw invocation, mentions included" do
      message = TitlePrompt.user_message(@launch_invocation)

      assert message =~ @launch_invocation
      assert message =~ "@getcontext.bot"
    end

    test "title-rewrite user turn includes invocation, compact reply, and writeup" do
      message =
        TitlePrompt.user_message(
          @launch_invocation,
          "Short compact about the launch.",
          "Full writeup with sources."
        )

      assert message =~ @launch_invocation
      assert message =~ "Short compact about the launch."
      assert message =~ "Full writeup with sources."
      refute message =~ "LENGTH_REPAIR"
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
