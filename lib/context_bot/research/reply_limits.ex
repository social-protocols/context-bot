defmodule ContextBot.Research.ReplyLimits do
  @moduledoc """
  Length and size constraints for Bluesky replies.

  Bluesky's hard limit is 300 Unicode grapheme clusters per post. To give the model margin for
  error, prompts target a smaller limit while validation accepts replies up to the full 300
  graphemes. A byte ceiling provides additional safety against unexpectedly large posts.

  A two-body split reserves one grapheme and three UTF-8 bytes for U+2026 on each
  published part. That reservation lives in the split/publish path, not in the
  prompt target.
  """

  @prompt_target_graphemes 275
  @hard_max_graphemes 300
  @max_bytes 3_000
  # U+2026 HORIZONTAL ELLIPSIS: 1 grapheme, 3 UTF-8 bytes.
  @continuation_ellipsis "…"

  @doc "The grapheme target shown in system prompts and repair instructions."
  def prompt_target_graphemes, do: @prompt_target_graphemes

  @doc "The actual Bluesky limit; replies exceeding this must be repaired or rejected."
  def hard_max_graphemes, do: @hard_max_graphemes

  @doc "Byte ceiling for additional safety."
  def max_bytes, do: @max_bytes

  @doc "U+2026 HORIZONTAL ELLIPSIS used to mark a continued two-body Bluesky split."
  @spec continuation_ellipsis() :: String.t()
  def continuation_ellipsis, do: @continuation_ellipsis

  @doc "Unicode grapheme-cluster count used for Bluesky publication."
  @spec graphemes(String.t()) :: non_neg_integer()
  def graphemes(text) when is_binary(text), do: String.length(text)

  @doc "UTF-8 byte size used for Bluesky publication."
  @spec bytes(String.t()) :: non_neg_integer()
  def bytes(text) when is_binary(text), do: byte_size(text)

  @doc "Publication counters for one string: graphemes and UTF-8 bytes."
  @spec measure(String.t()) :: %{graphemes: non_neg_integer(), bytes: non_neg_integer()}
  def measure(text) when is_binary(text) do
    %{graphemes: graphemes(text), bytes: bytes(text)}
  end

  @doc "True when the text fits in a single Bluesky post."
  @spec fits_one_post?(String.t()) :: boolean()
  def fits_one_post?(text) when is_binary(text) do
    measure = measure(text)
    measure.graphemes <= @hard_max_graphemes and measure.bytes <= @max_bytes
  end
end
