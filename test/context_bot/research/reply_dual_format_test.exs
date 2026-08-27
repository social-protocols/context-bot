defmodule ContextBot.Research.ReplyDualFormatTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Reply

  describe "select/2 with dual-format response" do
    test "parses dual-format response correctly" do
      content = [
        %{
          "type" => "text",
          "text" =>
            "This is a detailed research writeup\nwith multiple lines.\n\n" <>
              "---COMPACT_REPLY---\n" <>
              "Short summary for Bluesky"
        }
      ]

      assert {:ok, full, compact} = Reply.select(content, :end_turn)
      assert full == "This is a detailed research writeup\nwith multiple lines."
      assert compact == "Short summary for Bluesky"
    end

    test "parses a separator without surrounding newlines" do
      content = [
        %{
          "type" => "text",
          "text" => "Full writeup---COMPACT_REPLY---Short summary for Bluesky"
        }
      ]

      assert {:ok, full, compact} = Reply.select(content, :end_turn)
      assert full == "Full writeup"
      assert compact == "Short summary for Bluesky"
    end

    test "falls back to single format when separator not found" do
      content = [
        %{
          "type" => "text",
          "text" => "Just a regular reply without separator"
        }
      ]

      assert {:ok, text} = Reply.select(content, :end_turn)
      assert text == "Just a regular reply without separator"
    end

    test "handles repairable compact reply in dual format" do
      # 301 graphemes - over the limit
      long_compact = String.duplicate("a", 301)

      content = [
        %{
          "type" => "text",
          "text" => "Full response here\n---COMPACT_REPLY---\n#{long_compact}"
        }
      ]

      assert {:repairable, ^long_compact, [:too_many_graphemes]} =
               Reply.select(content, :end_turn)
    end

    test "requires both parts to be non-empty" do
      content = [
        %{
          "type" => "text",
          "text" => "\n---COMPACT_REPLY---\nOnly compact part"
        }
      ]

      assert {:ok, text} = Reply.select(content, :end_turn)
      assert text == "\n---COMPACT_REPLY---\nOnly compact part"
    end
  end

  describe "full_response_from_messages/1" do
    test "returns the full writeup from an earlier dual-format assistant turn" do
      messages = %{
        "messages" => [
          %{"role" => "user", "content" => "thread"},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "text",
                "text" => "Thorough markdown writeup.\n---COMPACT_REPLY---\nToo long compact"
              }
            ]
          },
          %{"role" => "user", "content" => "LENGTH_REPAIR\nReturn only the Bluesky reply text"}
        ]
      }

      assert Reply.full_response_from_messages(messages) == "Thorough markdown writeup."
    end

    test "returns nil when no assistant turn used dual format" do
      messages = %{
        "messages" => [
          %{"role" => "user", "content" => "thread"},
          %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "A single long reply"}]
          }
        ]
      }

      assert Reply.full_response_from_messages(messages) == nil
      assert Reply.full_response_from_messages(nil) == nil
    end
  end
end
