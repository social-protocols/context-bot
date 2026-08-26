defmodule ContextBot.Research.ReplyLimits do
  @moduledoc """
  Length and size constraints for Bluesky replies.

  Bluesky's hard limit is 300 Unicode grapheme clusters per post. To give the model margin for
  error, prompts target a smaller limit while validation accepts replies up to the full 300
  graphemes. A byte ceiling provides additional safety against unexpectedly large posts.
  """

  @prompt_target_graphemes 275
  @hard_max_graphemes 300
  @max_bytes 3_000

  @doc "The grapheme target shown in system prompts and repair instructions."
  def prompt_target_graphemes, do: @prompt_target_graphemes

  @doc "The actual Bluesky limit; replies exceeding this must be repaired or rejected."
  def hard_max_graphemes, do: @hard_max_graphemes

  @doc "Byte ceiling for additional safety."
  def max_bytes, do: @max_bytes

  @doc "True when the text fits in a single Bluesky post."
  @spec fits_one_post?(String.t()) :: boolean()
  def fits_one_post?(text) when is_binary(text) do
    String.length(text) <= @hard_max_graphemes and byte_size(text) <= @max_bytes
  end
end
