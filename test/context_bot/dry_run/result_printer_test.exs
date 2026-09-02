defmodule ContextBot.DryRun.ResultPrinterTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.Post
  alias ContextBot.DryRun.ResultPrinter
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Workflow.Invocation

  test "prints the full writeup before labeled posts and link placement" do
    compact = "Short Bluesky summary."
    full = "Line one of the writeup.\n\nLine two with sources."

    lines =
      ResultPrinter.format_complete(
        %Invocation{
          selected_reply: compact,
          full_response: full,
          anthropic_usage: %{
            "totals" => %{"input_tokens" => 8, "output_tokens" => 3},
            "tool_uses" => 1
          }
        },
        99
      )

    assert lines == [
             "status=complete",
             "answer=#{compact}",
             "usage input_tokens=8 output_tokens=3 tool_uses=1 cost_microdollars=99",
             "Full response:",
             full,
             "Post 1:",
             compact <> Post.link_suffix(),
             "(full response) link: Post 1"
           ]
  end

  test "prints a link-only post 2 when the compact reply cannot fit the suffix" do
    compact = String.duplicate("a", 285)
    full = "Thorough markdown writeup."

    lines =
      ResultPrinter.format_complete(
        %Invocation{selected_reply: compact, full_response: full},
        0
      )

    assert "Full response:" in lines
    assert full in lines
    assert_before(lines, "Full response:", "Post 1:")
    assert_before(lines, "Post 1:", "Post 2:")
    assert_before(lines, "Post 2:", "(full response) link: Post 2 (link alone)")
    assert Enum.at(lines, Enum.find_index(lines, &(&1 == "Post 1:")) + 1) == compact
    assert Enum.at(lines, Enum.find_index(lines, &(&1 == "Post 2:")) + 1) == Post.link_label()
  end

  test "prints both split posts when there is no full response" do
    part1 = String.duplicate("a", 150)
    part2 = String.duplicate("b", 160)

    lines =
      ResultPrinter.format_complete(
        %Invocation{
          selected_reply: part1,
          reply_validation: %{"result" => "split", "text_part2" => part2}
        },
        0
      )

    ellipsis = ReplyLimits.continuation_ellipsis()

    refute Enum.any?(lines, &String.starts_with?(&1, "Full response"))
    assert Enum.at(lines, Enum.find_index(lines, &(&1 == "Post 1:")) + 1) == part1 <> ellipsis
    assert Enum.at(lines, Enum.find_index(lines, &(&1 == "Post 2:")) + 1) == ellipsis <> part2
    assert List.last(lines) == "(full response) link: none"
  end

  test "a split with a full response shows remainder plus link on post 2" do
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 120)
    full = "Writeup kept from the dual-format turn."

    lines =
      ResultPrinter.format_complete(
        %Invocation{
          selected_reply: part1,
          full_response: full,
          reply_validation: %{"result" => "split", "text_part2" => remainder}
        },
        0
      )

    assert full in lines

    ellipsis = ReplyLimits.continuation_ellipsis()

    assert Enum.at(lines, Enum.find_index(lines, &(&1 == "Post 2:")) + 1) ==
             ellipsis <> remainder <> Post.link_suffix()

    assert List.last(lines) == "(full response) link: Post 2 (remainder + link)"
  end

  test "prints a completed no-reply without inventing posts or a writeup" do
    lines =
      ResultPrinter.format_complete(
        %Invocation{
          no_reply: true,
          selected_reply: nil,
          full_response: nil,
          reply_validation: %{"result" => "no_reply", "repair_used" => false},
          anthropic_usage: %{
            "totals" => %{"input_tokens" => 4, "output_tokens" => 1},
            "tool_uses" => 0
          }
        },
        12
      )

    assert lines == [
             "status=complete",
             "disposition=no_reply",
             "usage input_tokens=4 output_tokens=1 tool_uses=0 cost_microdollars=12",
             "(full response) link: none"
           ]
  end

  test "strips ANSI from the writeup and posts while keeping newlines" do
    lines =
      ResultPrinter.format_complete(
        %Invocation{
          selected_reply: "A concise\e[31m tested\nanswer.\e[0m",
          full_response: "Writeup\e[32m green\e[0m\nsecond line."
        },
        0
      )

    assert "Writeup green\nsecond line." in lines
    assert "A concise tested\nanswer. (full response)" in lines
    refute Enum.any?(lines, &String.contains?(&1, "\e"))
    assert hd(lines) == "status=complete"
    assert Enum.at(lines, 1) == "answer=A concise tested answer."
  end

  defp assert_before(lines, earlier, later) do
    earlier_index = Enum.find_index(lines, &(&1 == earlier))
    later_index = Enum.find_index(lines, &(&1 == later))
    assert earlier_index < later_index
  end
end
