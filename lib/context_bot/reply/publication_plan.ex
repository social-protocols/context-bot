defmodule ContextBot.Reply.PublicationPlan do
  @moduledoc """
  Decides the exact Bluesky post texts and where a full-response link would go.

  Ranking:

  1. Prefer the link in post 1 when compact plus ` (full response)` fits.
  2. Next, put post 2 as the link alone.
  3. Worst, remainder plus the link in post 2. Freeze avoids that whenever post 1
     still fits by using a link-only part 2 instead of leftover compact body.
  """

  alias ContextBot.ATProto.Post
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Workflow.Invocation

  @type link_placement :: :post_1 | :post_2_link_only | :post_2_remainder_and_link | :none

  @type t :: %{
          required(:posts) => [String.t()],
          required(:link_placement) => link_placement()
        }

  @type decision ::
          {:single_with_link, String.t()}
          | {:link_only_part2, String.t()}
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

      link_only_part2?(text, reader_url) ->
        {:link_only_part2, text}

      is_binary(remainder) ->
        {:body_split, text, remainder}

      true ->
        {:single, text}
    end
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

      {:body_split, text, rest} ->
        if present?(full_response) do
          %{
            posts: [text, rest <> Post.link_suffix()],
            link_placement: :post_2_remainder_and_link
          }
        else
          %{posts: [text, rest], link_placement: :none}
        end

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

  defp link_only_part2?(text, reader_url) when is_binary(reader_url),
    do: ReplyLimits.fits_one_post?(text)

  defp link_only_part2?(_text, _reader_url), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
