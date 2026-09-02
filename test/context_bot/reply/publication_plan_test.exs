defmodule ContextBot.Reply.PublicationPlanTest do
  use ExUnit.Case, async: true

  alias ContextBot.ATProto.Post
  alias ContextBot.Reply.PublicationPlan
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Workflow.Invocation

  test "keeps compact reply and full-response link in one post when they fit" do
    compact = String.duplicate("a", 250)
    full = "Thorough markdown writeup."

    assert PublicationPlan.preview(compact, nil, full) == %{
             posts: [compact <> Post.link_suffix()],
             link_placement: :post_1
           }

    assert PublicationPlan.decide(compact, nil, "https://standard-reader.app/a/did:plc:test/3k") ==
             {:single_with_link, compact}
  end

  test "puts the full-response link alone in post 2 when it does not fit with the compact reply" do
    compact = String.duplicate("a", 285)
    full = "Thorough markdown writeup."

    assert PublicationPlan.preview(compact, nil, full) == %{
             posts: [compact, Post.link_label()],
             link_placement: :post_2_link_only
           }

    assert PublicationPlan.decide(compact, nil, "https://standard-reader.app/a/did:plc:test/3k") ==
             {:link_only_part2, compact}
  end

  test "a body split with a full response keeps the remainder and the link on post 2" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 120)
    full = "Thorough markdown writeup."

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder <> Post.link_suffix()],
             link_placement: :post_2_remainder_and_link
           }

    assert Enum.any?(
             PublicationPlan.preview(part1, remainder, full).posts,
             &String.contains?(&1, remainder)
           )

    assert PublicationPlan.decide(
             part1,
             remainder,
             "https://standard-reader.app/a/did:plc:test/3k"
           ) ==
             {:post_2_remainder_and_link, part1 <> ellipsis, ellipsis <> remainder}
  end

  test "a body split whose remainder cannot fit the link uses a third link-only post" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 290)
    full = "Thorough markdown writeup."

    refute ReplyLimits.fits_one_post?(ellipsis <> remainder <> Post.link_suffix())

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder, Post.link_label()],
             link_placement: :post_3_link_only
           }

    assert PublicationPlan.decide(
             part1,
             remainder,
             "https://standard-reader.app/a/did:plc:test/3k"
           ) ==
             {:body_split_with_link_post3, part1 <> ellipsis, ellipsis <> remainder}
  end

  test "a body split without a full response publishes the remainder as post 2" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    assert PublicationPlan.preview(part1, remainder, nil) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder],
             link_placement: :none
           }

    assert PublicationPlan.decide(part1, remainder, nil) ==
             {:body_split, part1 <> ellipsis, ellipsis <> remainder}
  end

  test "a compact reply without a full response stays one post" do
    compact = "A concise tested answer."

    assert PublicationPlan.preview(compact, nil, nil) == %{
             posts: [compact],
             link_placement: :none
           }

    assert PublicationPlan.decide(compact, nil, nil) == {:single, compact}
  end

  test "reads the split remainder from dry-run reply_validation" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    invocation = %Invocation{
      selected_reply: part1,
      full_response: nil,
      reply_validation: %{"result" => "split", "text_part2" => remainder}
    }

    assert PublicationPlan.from_invocation(invocation) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder],
             link_placement: :none
           }
  end

  test "dry-run split with a full response keeps remainder plus link" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    invocation = %Invocation{
      selected_reply: part1,
      full_response: "Thorough markdown writeup.",
      reply_validation: %{"result" => "split", "text_part2" => remainder}
    }

    assert PublicationPlan.from_invocation(invocation) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder <> Post.link_suffix()],
             link_placement: :post_2_remainder_and_link
           }
  end

  test "a body split publishes continuation ellipses on both body posts" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    assert PublicationPlan.preview(part1, remainder, nil) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder],
             link_placement: :none
           }

    assert PublicationPlan.decide(part1, remainder, nil) ==
             {:body_split, part1 <> ellipsis, ellipsis <> remainder}
  end

  test "link-room math includes the leading ellipsis so 284 unmarked remainder needs post 3" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 284)
    full = "Thorough markdown writeup."

    assert ReplyLimits.fits_one_post?(remainder <> Post.link_suffix())
    refute ReplyLimits.fits_one_post?(ellipsis <> remainder <> Post.link_suffix())

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder, Post.link_label()],
             link_placement: :post_3_link_only
           }

    assert List.last(PublicationPlan.preview(part1, remainder, full).posts) == Post.link_label()
    refute String.contains?(Post.link_label(), ellipsis)
  end

  test "283 unmarked remainder plus leading ellipsis still keeps the link on post 2" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 283)
    full = "Thorough markdown writeup."

    assert ReplyLimits.fits_one_post?(ellipsis <> remainder <> Post.link_suffix())

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1 <> ellipsis, ellipsis <> remainder <> Post.link_suffix()],
             link_placement: :post_2_remainder_and_link
           }
  end

  test "a single-post compact and a link-only follow-up do not gain ellipses" do
    ellipsis = ReplyLimits.continuation_ellipsis()
    compact = String.duplicate("a", 250)
    oversize = String.duplicate("a", 285)
    full = "Thorough markdown writeup."

    single = PublicationPlan.preview(compact, nil, full)
    refute Enum.any?(single.posts, &String.contains?(&1, ellipsis))

    link_only = PublicationPlan.preview(oversize, nil, full)
    assert link_only.posts == [oversize, Post.link_label()]
    refute Enum.any?(link_only.posts, &String.contains?(&1, ellipsis))
  end
end
