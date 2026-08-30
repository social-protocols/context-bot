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
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 120)
    full = "Thorough markdown writeup."

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1, remainder <> Post.link_suffix()],
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
             {:post_2_remainder_and_link, part1, remainder}
  end

  test "a body split whose remainder cannot fit the link uses a third link-only post" do
    part1 = String.duplicate("a", 208)
    remainder = String.duplicate("b", 290)
    full = "Thorough markdown writeup."

    refute ReplyLimits.fits_one_post?(remainder <> Post.link_suffix())

    assert PublicationPlan.preview(part1, remainder, full) == %{
             posts: [part1, remainder, Post.link_label()],
             link_placement: :post_3_link_only
           }

    assert PublicationPlan.decide(
             part1,
             remainder,
             "https://standard-reader.app/a/did:plc:test/3k"
           ) ==
             {:body_split_with_link_post3, part1, remainder}
  end

  test "a body split without a full response publishes the remainder as post 2" do
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    assert PublicationPlan.preview(part1, remainder, nil) == %{
             posts: [part1, remainder],
             link_placement: :none
           }

    assert PublicationPlan.decide(part1, remainder, nil) == {:body_split, part1, remainder}
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
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    invocation = %Invocation{
      selected_reply: part1,
      full_response: nil,
      reply_validation: %{"result" => "split", "text_part2" => remainder}
    }

    assert PublicationPlan.from_invocation(invocation) == %{
             posts: [part1, remainder],
             link_placement: :none
           }
  end

  test "dry-run split with a full response keeps remainder plus link" do
    part1 = String.duplicate("a", 150)
    remainder = String.duplicate("b", 160)

    invocation = %Invocation{
      selected_reply: part1,
      full_response: "Thorough markdown writeup.",
      reply_validation: %{"result" => "split", "text_part2" => remainder}
    }

    assert PublicationPlan.from_invocation(invocation) == %{
             posts: [part1, remainder <> Post.link_suffix()],
             link_placement: :post_2_remainder_and_link
           }
  end
end
