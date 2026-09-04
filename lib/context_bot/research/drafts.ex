defmodule ContextBot.Research.Drafts do
  @moduledoc """
  Parseable research-phase title and compact_reply drafts.

  Research writes these at the top of the writeup. Structure prefers them as
  the starting point and may shorten or lightly rewrite them to fit the
  Bluesky hard cap. Length counts are measured in code with the same
  grapheme and byte counters used for publication.
  """

  alias ContextBot.Research.ReplyLimits

  @open "CONTEXT_BOT_DRAFT"
  @close "CONTEXT_BOT_DRAFT_END"
  @header ~r/\Atitle:[ \t]*([^\r\n]*)\r?\ncompact_reply:[ \t]*/u

  @type t :: %{title: String.t(), compact_reply: String.t()}

  @type measured :: %{
          title: String.t(),
          compact_reply: String.t(),
          title_graphemes: non_neg_integer(),
          title_bytes: non_neg_integer(),
          compact_graphemes: non_neg_integer(),
          compact_bytes: non_neg_integer(),
          compact_over_graphemes: non_neg_integer(),
          compact_over_bytes: non_neg_integer()
        }

  @spec open_marker() :: String.t()
  def open_marker, do: @open

  @spec close_marker() :: String.t()
  def close_marker, do: @close

  @doc "Renders the labeled draft block research is asked to emit."
  @spec format(String.t(), String.t()) :: String.t()
  def format(title, compact_reply) when is_binary(title) and is_binary(compact_reply) do
    """
    #{@open}
    title: #{String.trim(title)}
    compact_reply: #{String.trim(compact_reply)}
    #{@close}
    """
    |> String.trim()
  end

  @doc """
  Extracts the first draft block from a writeup.

  Returns `:error` when markers or the title/compact_reply labels are missing.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(writeup) when is_binary(writeup) do
    case split_once(writeup, @open <> "\n") || split_once(writeup, @open <> "\r\n") do
      {_before, rest} ->
        case split_once(rest, "\n" <> @close) || split_once(rest, "\r\n" <> @close) do
          {body, _after} -> parse_body(body)
          nil -> :error
        end

      nil ->
        :error
    end
  end

  def parse(_writeup), do: :error

  @doc """
  Parses drafts and attaches publication grapheme/byte counts.

  Returns `:error` when the block is missing or malformed. Callers must not
  invent draft text or counts on a miss.
  """
  @spec parse_measured(String.t()) :: {:ok, measured()} | :error
  def parse_measured(writeup) do
    case parse(writeup) do
      {:ok, drafts} -> {:ok, measure(drafts)}
      :error -> :error
    end
  end

  @spec measure(t()) :: measured()
  def measure(%{title: title, compact_reply: compact})
      when is_binary(title) and is_binary(compact) do
    title_count = ReplyLimits.measure(title)
    compact_count = ReplyLimits.measure(compact)

    %{
      title: title,
      compact_reply: compact,
      title_graphemes: title_count.graphemes,
      title_bytes: title_count.bytes,
      compact_graphemes: compact_count.graphemes,
      compact_bytes: compact_count.bytes,
      compact_over_graphemes: max(compact_count.graphemes - ReplyLimits.hard_max_graphemes(), 0),
      compact_over_bytes: max(compact_count.bytes - ReplyLimits.max_bytes(), 0)
    }
  end

  @doc """
  Structure-turn banner with parsed drafts and code-measured lengths.

  Returns `""` when drafts cannot be parsed so the structure call does not
  invent a draft that was not in the writeup.
  """
  @spec structure_banner(String.t()) :: String.t()
  def structure_banner(writeup) when is_binary(writeup) do
    case parse_measured(writeup) do
      {:ok, measured} -> structure_banner_text(measured)
      :error -> ""
    end
  end

  def structure_banner(_writeup), do: ""

  defp structure_banner_text(measured) do
    """
    Research drafts (starting point; shorten or lightly rewrite only as needed to meet the hard cap. Do not self-count; use the measured lengths below):
    title: #{measured.title}
    title_length: #{measured.title_graphemes} graphemes / #{measured.title_bytes} bytes
    compact_reply: #{measured.compact_reply}
    compact_length: #{measured.compact_graphemes} graphemes / #{measured.compact_bytes} bytes
    hard_cap: #{ReplyLimits.hard_max_graphemes()} graphemes / #{ReplyLimits.max_bytes()} bytes
    #{over_cap_line(measured)}
    """
  end

  defp over_cap_line(%{compact_over_graphemes: 0, compact_over_bytes: 0}),
    do: "over_cap: none"

  defp over_cap_line(%{compact_over_graphemes: graphemes, compact_over_bytes: bytes})
       when graphemes > 0 and bytes > 0 do
    "over_cap: compact is #{graphemes} graphemes and #{bytes} bytes over; shorten by about #{graphemes} graphemes"
  end

  defp over_cap_line(%{compact_over_graphemes: graphemes}) when graphemes > 0 do
    "over_cap: compact is #{graphemes} graphemes over; shorten by about #{graphemes} graphemes"
  end

  defp over_cap_line(%{compact_over_bytes: bytes}) do
    "over_cap: compact is #{bytes} bytes over; shorten to at most #{ReplyLimits.max_bytes()} bytes"
  end

  defp parse_body(body) do
    case Regex.run(@header, body) do
      [matched, title] ->
        compact = body |> String.replace_prefix(matched, "") |> String.trim()
        {:ok, %{title: String.trim(title), compact_reply: compact}}

      nil ->
        :error
    end
  end

  defp split_once(text, delimiter) do
    case String.split(text, delimiter, parts: 2) do
      [left, right] -> {left, right}
      _missing -> nil
    end
  end
end
