defmodule ContextBot.Research.StructuredFixtures do
  @moduledoc false

  alias ContextBot.Research.Drafts

  @default_title "Context Request"

  @doc """
  Inv 37-shaped thread: a meta comment with no question or research request.
  """
  @spec inv37_thread() :: String.t()
  def inv37_thread do
    """
    ROOT
    A thread making an argument.

    INVOCATION
    @getcontext.bot Not making a good argument for trusting bots.
    """
    |> String.trim()
  end

  @doc """
  Inv 35-shaped thread: a claim-only counterargument with no question or
  request aimed at the bot (diogeneslamp shape).
  """
  @spec inv35_thread() :: String.t()
  def inv35_thread do
    """
    ROOT
    A thread arguing about pandemic origins.

    INVOCATION
    @getcontext.bot The zoonosis studies are clear. The FBI/GenBank claim is also documented.
    """
    |> String.trim()
  end

  @doc """
  Inv 35-shaped writeup: empty CONTEXT_BOT_DRAFT plus a note that the
  mention is a claim-only counterargument and no published reply is needed.
  """
  @spec inv35_writeup() :: String.t()
  def inv35_writeup do
    Drafts.format("", "") <> "\n\n" <> inv35_essay()
  end

  @spec inv35_essay() :: String.t()
  def inv35_essay do
    """
    The invoking mention is a counterargument that asserts checkable claims
    but does not ask this bot anything: zoonosis studies and an FBI/GenBank
    claim. That is not an obvious question or request aimed at this bot.

    Do not fact-check a claim-dump just because the claims are verifiable.
    No published reply is needed.
    """
    |> String.trim()
  end

  @doc """
  Inv 37-shaped writeup: empty CONTEXT_BOT_DRAFT plus a note that there is
  no discernible question and no published reply is needed.
  """
  @spec inv37_writeup() :: String.t()
  def inv37_writeup do
    Drafts.format("", "") <> "\n\n" <> inv37_essay()
  end

  @spec inv37_essay() :: String.t()
  def inv37_essay do
    """
    The invoking mention is a meta comment, not a question or request for research
    or context: "Not making a good argument for trusting bots."

    There is no discernible question directed at this bot. The actor is commenting
    on whether the thread makes a good argument for trusting bots. That is not a
    request for sources, a fact-check, or other research.

    No published reply is needed.
    """
    |> String.trim()
  end

  @spec structured_json(String.t(), keyword()) :: String.t()
  def structured_json(compact, opts \\ []) when is_binary(compact) do
    Jason.encode!(structured_map(compact, opts))
  end

  @spec no_reply_json(keyword()) :: String.t()
  def no_reply_json(opts \\ []) do
    Jason.encode!(
      %{
        "disposition" => "no_reply",
        "title" => Keyword.get(opts, :title, ""),
        "compact_reply" => Keyword.get(opts, :compact, "")
      }
      |> maybe_put_full(Keyword.get(opts, :full, :omit))
      |> maybe_drop_empty_fields(Keyword.get(opts, :omit_fields, false))
    )
  end

  @spec selected(String.t(), keyword()) ::
          {:ok,
           %{
             text: String.t(),
             full_response: String.t(),
             document_title: String.t(),
             disposition: :reply
           }}
  def selected(compact, opts \\ []) when is_binary(compact) do
    {:ok,
     %{
       text: compact,
       full_response: Keyword.get(opts, :full, ""),
       document_title: Keyword.get(opts, :title, @default_title),
       disposition: :reply
     }}
  end

  defp structured_map(compact, opts) do
    %{
      "disposition" => Keyword.get(opts, :disposition, "reply"),
      "title" => Keyword.get(opts, :title, @default_title),
      "compact_reply" => compact
    }
    |> maybe_put_full(Keyword.get(opts, :full, :omit))
    |> maybe_omit_disposition(Keyword.get(opts, :omit_disposition, false))
  end

  defp maybe_put_full(map, :omit), do: map
  defp maybe_put_full(map, full) when is_binary(full), do: Map.put(map, "full_response", full)

  defp maybe_omit_disposition(map, true), do: Map.delete(map, "disposition")
  defp maybe_omit_disposition(map, _false), do: map

  defp maybe_drop_empty_fields(map, true) do
    Map.drop(map, ["title", "compact_reply", "full_response"])
  end

  defp maybe_drop_empty_fields(map, _false), do: map
end
