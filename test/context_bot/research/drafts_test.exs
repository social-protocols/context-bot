defmodule ContextBot.Research.DraftsTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.{Citations, Drafts, ReplyLimits}

  test "formats and parses a labeled draft block from a writeup" do
    title = "What Is That Bird?"
    compact = "A Himalayan Monal."
    writeup = Drafts.format(title, compact) <> "\n\nThorough cited writeup."

    assert {:ok, %{title: ^title, compact_reply: ^compact}} = Drafts.parse(writeup)
    assert {:ok, measured} = Drafts.parse_measured(writeup)
    assert measured.title == title
    assert measured.compact_reply == compact
    assert measured.title_graphemes == ReplyLimits.graphemes(title)
    assert measured.title_bytes == ReplyLimits.bytes(title)
    assert measured.compact_graphemes == ReplyLimits.graphemes(compact)
    assert measured.compact_bytes == ReplyLimits.bytes(compact)
    assert measured.compact_over_graphemes == 0
    assert measured.compact_over_bytes == 0
  end

  test "measures how far an over-cap compact is past the publication counters" do
    compact = String.duplicate("a", 412)
    writeup = Drafts.format("Over", compact) <> "\n\nWriteup."

    assert {:ok, measured} = Drafts.parse_measured(writeup)
    assert measured.compact_graphemes == 412
    assert measured.compact_bytes == 412
    assert measured.compact_over_graphemes == 112
    assert measured.compact_over_bytes == 0
    assert ReplyLimits.graphemes(compact) == 412
    refute ReplyLimits.fits_one_post?(compact)
  end

  test "returns error on a parse miss and does not invent drafts" do
    assert Drafts.parse("Thorough writeup with no draft block.") == :error
    assert Drafts.parse_measured("Thorough writeup with no draft block.") == :error
    assert Drafts.structure_banner("Thorough writeup with no draft block.") == ""
    assert Drafts.parse("CONTEXT_BOT_DRAFT\nmissing labels\nCONTEXT_BOT_DRAFT_END") == :error
  end

  test "structure banner omits the raw over-cap compact and keeps measured counts" do
    compact = String.duplicate("b", 350)
    writeup = Drafts.format("Mostly True?", compact) <> "\n\nWriteup."
    banner = Drafts.structure_banner(writeup)

    assert banner =~ "Research drafts (starting point"
    assert banner =~ "Do not self-count"
    assert banner =~ "title: Mostly True?"
    assert banner =~ "title_length: #{ReplyLimits.graphemes("Mostly True?")} graphemes"
    refute banner =~ compact
    refute banner =~ "compact_reply: #{compact}"
    assert banner =~ "compact_reply: (omitted; over cap"
    assert banner =~ "compact_length: 350 graphemes / 350 bytes"
    assert banner =~ "hard_cap: 300 graphemes / 3000 bytes"
    assert banner =~ "over_cap: compact is 50 graphemes over; shorten by about 50 graphemes"
  end

  test "structure banner omits a similarly huge title and keeps title_length" do
    title = String.duplicate("T", 400)
    compact = "A Himalayan Monal."
    writeup = Drafts.format(title, compact) <> "\n\nWriteup."
    banner = Drafts.structure_banner(writeup)

    refute banner =~ title
    refute banner =~ "title: #{title}"
    assert banner =~ "title: (omitted; over cap"
    assert banner =~ "title_length: 400 graphemes / 400 bytes"
    assert banner =~ "compact_reply: #{compact}"
  end

  test "structure banner includes in-cap draft text and reports over_cap none" do
    compact = "A Himalayan Monal."
    writeup = Drafts.format("Bird", compact) <> "\n\nWriteup."
    banner = Drafts.structure_banner(writeup)

    assert banner =~ "title: Bird"
    assert banner =~ "compact_reply: #{compact}"
    assert banner =~ "over_cap: none"
    refute banner =~ "shorten by"
    refute banner =~ "(omitted; over cap"
  end

  test "publishable_writeup keeps the draft block parseable" do
    drafts = Drafts.format("Bird", "A Himalayan Monal.")
    writeup = drafts <> "\n\nUseful context from primary sources."

    published =
      Citations.publishable_writeup(writeup, [
        %{
          "url" => "https://primary.example/report",
          "cited_text" => "Useful context from primary sources.",
          "span" => "Useful context from primary sources."
        }
      ])

    assert {:ok, %{title: "Bird", compact_reply: "A Himalayan Monal."}} = Drafts.parse(published)
    assert published =~ "## Sources"
  end
end
