defmodule ContextBot.Research.ReplyDualFormatTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.Reply
  alias ContextBot.Research.StructuredFixtures

  describe "select/2 with structured JSON" do
    test "selects title, compact reply, and full markdown from valid JSON" do
      content = [
        %{
          "type" => "text",
          "text" =>
            StructuredFixtures.structured_json("Short summary for Bluesky",
              title: "What Is That Bird?",
              full: "This is a detailed research writeup\nwith multiple lines."
            )
        }
      ]

      assert {:ok, selected} = Reply.select(content, :end_turn)
      assert selected.text == "Short summary for Bluesky"
      assert selected.full_response == "This is a detailed research writeup\nwith multiple lines."
      assert selected.document_title == "What Is That Bird?"
      assert selected.disposition == :reply
    end

    test "concatenates split JSON text blocks before decoding" do
      encoded =
        StructuredFixtures.structured_json("Short summary for Bluesky",
          title: "Context Bot Launch",
          full: "Full writeup"
        )

      {first, second} = String.split_at(encoded, div(String.length(encoded), 2))

      content = [
        %{"type" => "text", "text" => first},
        %{"type" => "text", "text" => second}
      ]

      assert {:ok, selected} = Reply.select(content, :end_turn)
      assert selected.text == "Short summary for Bluesky"
      assert selected.full_response == "Full writeup"
      assert selected.document_title == "Context Bot Launch"
    end

    test "fails closed when the model returns prose instead of JSON" do
      content = [
        %{
          "type" => "text",
          "text" => "Just a regular reply without JSON"
        }
      ]

      assert Reply.select(content, :end_turn) == {:error, :invalid_structured_output}
    end

    test "fails closed when required JSON fields are missing or blank" do
      for text <- [
            ~s({"title":"Bird","compact_reply":"Short"}),
            ~s({"title":"Bird","compact_reply":"Short","full_response":""}),
            ~s({"title":"","compact_reply":"Short","full_response":"Writeup."}),
            ~s({"title":"Bird","compact_reply":"","full_response":"Writeup."}),
            ~s({"title":1,"compact_reply":"Short","full_response":"Writeup."}),
            ~s({"disposition":"reply","title":"Bird","compact_reply":"Short","full_response":""}),
            ~s({"disposition":"maybe","title":"Bird","compact_reply":"Short","full_response":"Writeup."}),
            ~s({"disposition":true,"title":"Bird","compact_reply":"Short","full_response":"Writeup."}),
            "---COMPACT_REPLY---\nlegacy delimiter"
          ] do
        assert Reply.select([%{"type" => "text", "text" => text}], :end_turn) ==
                 {:error, :invalid_structured_output}
      end
    end

    test "selects no_reply when the mention is clearly not a request" do
      for text <- [
            StructuredFixtures.no_reply_json(),
            StructuredFixtures.no_reply_json(omit_fields: true),
            StructuredFixtures.no_reply_json(title: "Unused", compact: "unused", full: "unused")
          ] do
        assert {:ok, selected} = Reply.select([%{"type" => "text", "text" => text}], :end_turn)
        assert selected.disposition == :no_reply
        assert selected.text == ""
        assert selected.full_response == ""
        assert selected.document_title == ""
      end
    end

    test "treats legacy JSON without disposition as a reply" do
      content = [
        %{
          "type" => "text",
          "text" =>
            StructuredFixtures.structured_json("Short summary for Bluesky",
              title: "What Is That Bird?",
              full: "Writeup.",
              omit_disposition: true
            )
        }
      ]

      assert {:ok, selected} = Reply.select(content, :end_turn)
      assert selected.disposition == :reply
      assert selected.text == "Short summary for Bluesky"
    end

    test "handles a repairable compact reply inside JSON" do
      long_compact = String.duplicate("a", 301)

      content = [
        %{
          "type" => "text",
          "text" =>
            StructuredFixtures.structured_json(long_compact,
              title: "Overlong Reply",
              full: "Full response here"
            )
        }
      ]

      assert {:repairable, ^long_compact, [:too_many_graphemes]} =
               Reply.select(content, :end_turn)
    end

    test "decodes leftover JSON unicode escapes in compact_reply and title" do
      leftover = leftover_unicode_escape("2014")
      compact = "not a layoff forecast" <> leftover <> "the county itself says"
      title = "Jobs" <> leftover <> "risk"
      full = "Writeup with a real em dash — already decoded."

      assert leftover == <<?\\, ?u, ?2, ?0, ?1, ?4>>
      refute String.contains?(compact, "—")

      encoded = StructuredFixtures.structured_json(compact, title: title, full: full)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["compact_reply"] == compact
      assert decoded["title"] == title

      assert {:ok, selected} = Reply.select([%{"type" => "text", "text" => encoded}], :end_turn)
      assert selected.text == "not a layoff forecast—the county itself says"
      assert selected.document_title == "Jobs—risk"
      refute String.contains?(selected.text, leftover)
      refute String.contains?(selected.document_title, leftover)
      assert selected.full_response == full
    end

    test "leaves a real em dash in compact_reply unchanged" do
      compact = "not a layoff forecast—the county itself says"

      assert {:ok, selected} =
               Reply.select(
                 [
                   %{
                     "type" => "text",
                     "text" => StructuredFixtures.structured_json(compact)
                   }
                 ],
                 :end_turn
               )

      assert selected.text == compact
      assert String.contains?(selected.text, "—")
      refute String.contains?(selected.text, leftover_unicode_escape("2014"))
    end

    test "decodes leftover \\u2019 as a right single quote" do
      leftover = leftover_unicode_escape("2019")
      compact = "the county" <> leftover <> "s report"

      assert leftover == <<?\\, ?u, ?2, ?0, ?1, ?9>>
      refute String.contains?(compact, "\u2019")

      assert {:ok, selected} =
               Reply.select(
                 [
                   %{
                     "type" => "text",
                     "text" => StructuredFixtures.structured_json(compact)
                   }
                 ],
                 :end_turn
               )

      assert selected.text == "the county\u2019s report"
      refute String.contains?(selected.text, leftover)
    end

    test "decodes leftover \\u2014 beside a real em dash" do
      leftover = leftover_unicode_escape("2014")
      compact = "modeled estimate—not a layoff" <> leftover <> "the county"

      assert String.contains?(compact, "—")
      assert String.contains?(compact, leftover)

      assert {:ok, selected} =
               Reply.select(
                 [
                   %{
                     "type" => "text",
                     "text" => StructuredFixtures.structured_json(compact)
                   }
                 ],
                 :end_turn
               )

      assert selected.text == "modeled estimate—not a layoff—the county"
      refute String.contains?(selected.text, leftover)
      assert selected.text |> String.graphemes() |> Enum.count(&(&1 == "—")) == 2
    end
  end

  describe "full_response_from_messages/1 and document_title_from_messages/1" do
    test "returns the writeup and title from an earlier structured assistant turn" do
      messages = %{
        "messages" => [
          %{"role" => "user", "content" => "thread"},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  StructuredFixtures.structured_json("Too long compact",
                    title: "What Is That Bird?",
                    full: "Thorough markdown writeup."
                  )
              }
            ]
          },
          %{"role" => "user", "content" => "LENGTH_REPAIR\nReturn the same JSON object"}
        ]
      }

      assert Reply.full_response_from_messages(messages) == "Thorough markdown writeup."
      assert Reply.document_title_from_messages(messages) == "What Is That Bird?"
    end

    test "returns nil when no assistant turn used structured JSON" do
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
      assert Reply.document_title_from_messages(messages) == nil
      assert Reply.full_response_from_messages(nil) == nil
      assert Reply.document_title_from_messages(nil) == nil
    end
  end

  # After Jason.decode, a model-written JSON `\\uXXXX` is the six characters `\uXXXX`.
  defp leftover_unicode_escape(hex) when is_binary(hex) and byte_size(hex) == 4 do
    "\\u#{hex}"
  end
end
