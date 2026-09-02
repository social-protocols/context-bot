defmodule ContextBot.Reply.PublicationPlan do
  @moduledoc """
  Decides the exact Bluesky post texts and where a full-response link would go.

  Ranking:

  1. No remainder, and compact plus ` (full response)` fits → one post.
  2. No remainder, compact fits but plus the link does not → post 1 compact,
     post 2 link-only.
  3. Remainder present → post 1 is part 1 with a trailing U+2026, and post 2
     is part 2 with a leading U+2026. Post 2 also carries the link when that
     marked remainder plus ` (full response)` still fits
     (`:post_2_remainder_and_link`). If it does not fit, post 2 is the marked
     remainder and post 3 is the unchanged link-only label. Never drop part 2.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Research.Reply
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Workflow.Invocation

  @type link_placement ::
          :post_1 | :post_2_link_only | :post_2_remainder_and_link | :post_3_link_only | :none

  @type t :: %{
          required(:posts) => [String.t()],
          required(:link_placement) => link_placement()
        }

  @type decision ::
          {:single_with_link, String.t()}
          | {:link_only_part2, String.t()}
          | {:post_2_remainder_and_link, String.t(), String.t()}
          | {:body_split_with_link_post3, String.t(), String.t()}
          | {:body_split, String.t(), String.t()}
          | {:single, String.t()}

  @doc """
  Classifies how a compact reply, optional remainder, and reader URL freeze into posts.
  """
  @spec decide(String.t(), String.t() | nil, String.t() | nil) :: decision()
  def decide(text, remainder, reader_url) when is_binary(text) do
    cond do
      single_post_with_link?(text, remainder, reader_url) ->
        {:single_with_link, text}

      is_nil(remainder) and is_binary(reader_url) ->
        {:link_only_part2, text}

      is_binary(remainder) ->
        remainder_decision(text, remainder, reader_url)

      true ->
        {:single, text}
    end
  end

  defp remainder_decision(text, remainder, reader_url) when is_binary(reader_url) do
    {part1, part2} = Reply.with_continuation_ellipses(text, remainder)

    if remainder_and_link_fits?(part2) do
      {:post_2_remainder_and_link, part1, part2}
    else
      {:body_split_with_link_post3, part1, part2}
    end
  end

  defp remainder_decision(text, remainder, _reader_url) do
    {part1, part2} = Reply.with_continuation_ellipses(text, remainder)
    {:body_split, part1, part2}
  end

  @doc """
  Returns the exact post texts a dry-run would publish and where the link would go.

  A nonempty `full_response` is treated as a reader URL being available, without
  requiring Standard.site publication.
  """
  @spec preview(String.t() | nil, String.t() | nil, String.t() | nil) :: t()
  def preview(compact, remainder, full_response)

  def preview(compact, remainder, full_response) when is_binary(compact) do
    reader_url = if present?(full_response), do: "local://full-response", else: nil
    remainder = if present?(remainder), do: remainder, else: nil

    case decide(compact, remainder, reader_url) do
      {:single_with_link, text} ->
        %{posts: [text <> Post.link_suffix()], link_placement: :post_1}

      {:link_only_part2, text} ->
        %{posts: [text, Post.link_label()], link_placement: :post_2_link_only}

      {:post_2_remainder_and_link, text, rest} ->
        %{
          posts: [text, rest <> Post.link_suffix()],
          link_placement: :post_2_remainder_and_link
        }

      {:body_split_with_link_post3, text, rest} ->
        %{posts: [text, rest, Post.link_label()], link_placement: :post_3_link_only}

      {:body_split, text, rest} ->
        %{posts: [text, rest], link_placement: :none}

      {:single, text} ->
        %{posts: [text], link_placement: :none}
    end
  end

  def preview(_compact, _remainder, _full_response), do: %{posts: [], link_placement: :none}

  @spec from_invocation(Invocation.t()) :: t()
  def from_invocation(%Invocation{} = invocation) do
    preview(invocation.selected_reply, remainder(invocation), invocation.full_response)
  end

  defp remainder(%Invocation{reply_validation: %{"text_part2" => part2}})
       when is_binary(part2) and part2 != "",
       do: part2

  defp remainder(_invocation), do: nil

  defp single_post_with_link?(text, nil, reader_url) when is_binary(reader_url),
    do: ReplyLimits.fits_one_post?(text <> Post.link_suffix())

  defp single_post_with_link?(_text, _remainder, _reader_url), do: false

  defp remainder_and_link_fits?(remainder),
    do: ReplyLimits.fits_one_post?(remainder <> Post.link_suffix())

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
