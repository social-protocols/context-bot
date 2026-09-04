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

  test "strip/1 removes the draft block and leaves the essay" do
    essay = "Thorough cited writeup.\n\n## Sources\n\n[Report](https://primary.example/report)"
    writeup = Drafts.format("What Is That Bird?", "A Himalayan Monal.") <> "\n\n" <> essay

    stripped = Drafts.strip(writeup)

    assert stripped == essay
    refute stripped =~ Drafts.open_marker()
    refute stripped =~ Drafts.close_marker()
    refute stripped =~ "title: What Is That Bird?"
    refute stripped =~ "compact_reply: A Himalayan Monal."
    assert Drafts.strip(stripped) == essay
  end

  test "strip/1 is a no-op when the draft block is absent" do
    essay = "Thorough writeup with no draft block.\n\nKeep every paragraph."

    assert Drafts.strip(essay) == essay
    assert Drafts.strip("") == ""
  end

  test "strip/1 matches parse marker variants and surrounding whitespace" do
    essay = "Essay after a CRLF draft."

    crlf =
      "CONTEXT_BOT_DRAFT\r\ntitle: Bird\r\ncompact_reply: A Himalayan Monal.\r\nCONTEXT_BOT_DRAFT_END\r\n\r\n" <>
        essay

    assert Drafts.parse(crlf) == {:ok, %{title: "Bird", compact_reply: "A Himalayan Monal."}}
    assert Drafts.strip(crlf) == essay

    padded = "\n\n" <> Drafts.format("Bird", "A Himalayan Monal.") <> "\n\n\n" <> essay
    assert Drafts.parse(padded) == {:ok, %{title: "Bird", compact_reply: "A Himalayan Monal."}}
    assert Drafts.strip(padded) == essay

    preface = "Keep this preface.\n\n" <> Drafts.format("Bird", "Short.") <> "\n\n" <> essay
    assert Drafts.strip(preface) == "Keep this preface.\n\n" <> essay
    refute Drafts.strip(preface) =~ Drafts.open_marker()
  end

  test "strip/1 removes a complete marker block even when labels are malformed" do
    writeup = "CONTEXT_BOT_DRAFT\nmissing labels\nCONTEXT_BOT_DRAFT_END\n\nEssay remains."

    assert Drafts.parse(writeup) == :error
    assert Drafts.strip(writeup) == "Essay remains."
    refute Drafts.strip(writeup) =~ Drafts.open_marker()
  end

  test "truncate_to_cap/1 keeps in-cap text and slices over-cap text to the hard caps" do
    in_cap = String.duplicate("a", 300)
    assert Drafts.truncate_to_cap(in_cap) == in_cap
    assert Drafts.truncate_to_cap("short") == "short"

    over_graphemes = String.duplicate("b", 350)
    truncated = Drafts.truncate_to_cap(over_graphemes)
    assert truncated == String.duplicate("b", 300)
    assert ReplyLimits.fits_one_post?(truncated)
    refute ReplyLimits.fits_one_post?(over_graphemes)

    # 273 ZWJ emoji sequences are 273 graphemes / 3,003 bytes — over the byte cap.
    over_bytes = String.duplicate("👩‍💻", 273)
    refute ReplyLimits.fits_one_post?(over_bytes)
    truncated_bytes = Drafts.truncate_to_cap(over_bytes)
    assert ReplyLimits.fits_one_post?(truncated_bytes)
    assert ReplyLimits.graphemes(truncated_bytes) < ReplyLimits.graphemes(over_bytes)
    assert String.starts_with?(over_bytes, truncated_bytes)
  end

  test "structure banner includes the full over-cap compact plus a truncated seed and measured counts" do
    compact = String.duplicate("b", 350)
    writeup = Drafts.format("Mostly True?", compact) <> "\n\nWriteup."
    banner = Drafts.structure_banner(writeup)
    seed = Drafts.truncate_to_cap(compact)

    assert banner =~ "Research drafts (starting point"
    assert banner =~ "Do not self-count"
    assert banner =~ "title: Mostly True?"
    assert banner =~ "title_length: #{ReplyLimits.graphemes("Mostly True?")} graphemes"
    assert banner =~ "compact_reply: #{compact}"
    refute banner =~ "(omitted; over cap"
    assert banner =~ "compact_reply_seed: #{seed}"
    assert ReplyLimits.graphemes(seed) == 300
    assert banner =~ "compact_length: 350 graphemes / 350 bytes"
    assert banner =~ "hard_cap: 300 graphemes / 3000 bytes"
    assert banner =~ "over_cap: compact is 50 graphemes over; shorten by about 50 graphemes"
  end

  test "structure banner includes the full over-cap title plus a truncated seed and title_length" do
    title = String.duplicate("T", 400)
    compact = "A Himalayan Monal."
    writeup = Drafts.format(title, compact) <> "\n\nWriteup."
    banner = Drafts.structure_banner(writeup)
    seed = Drafts.truncate_to_cap(title)

    assert banner =~ "title: #{title}"
    refute banner =~ "(omitted; over cap"
    assert banner =~ "title_seed: #{seed}"
    assert ReplyLimits.graphemes(seed) == 300
    assert banner =~ "title_length: 400 graphemes / 400 bytes"
    assert banner =~ "compact_reply: #{compact}"
    refute banner =~ "compact_reply_seed:"
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
    refute banner =~ "compact_reply_seed:"
    refute banner =~ "title_seed:"
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
