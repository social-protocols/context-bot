defmodule ContextBot.DryRun.ResultPrinter do
  @moduledoc """
  Formats a completed local dry-run: full writeup, exact Bluesky posts, and link placement.
  """

  alias ContextBot.Reply.PublicationPlan
  alias ContextBot.Workflow.Invocation

  @spec format_complete(Invocation.t(), non_neg_integer()) :: [String.t()]
  def format_complete(%Invocation{no_reply: true} = invocation, cost_microdollars)
      when is_integer(cost_microdollars) and cost_microdollars >= 0 do
    totals = get_in(invocation.anthropic_usage || %{}, ["totals"]) || %{}

    [
      "status=complete",
      "disposition=no_reply",
      usage_line(totals, invocation, cost_microdollars),
      link_line(:none)
    ]
  end

  def format_complete(%Invocation{} = invocation, cost_microdollars)
      when is_integer(cost_microdollars) and cost_microdollars >= 0 do
    totals = get_in(invocation.anthropic_usage || %{}, ["totals"]) || %{}
    plan = PublicationPlan.from_invocation(invocation)

    [
      "status=complete",
      "answer=#{one_line(invocation.selected_reply)}",
      usage_line(totals, invocation, cost_microdollars)
    ] ++
      full_response_section(invocation.full_response) ++
      post_section(plan.posts) ++
      [link_line(plan.link_placement)]
  end

  defp usage_line(totals, invocation, cost_microdollars) do
    "usage input_tokens=#{integer(totals["input_tokens"])} " <>
      "output_tokens=#{integer(totals["output_tokens"])} " <>
      "tool_uses=#{integer((invocation.anthropic_usage || %{})["tool_uses"])} " <>
      "cost_microdollars=#{integer(cost_microdollars)}"
  end

  defp full_response_section(full) when is_binary(full) do
    case String.trim(sanitize_multiline(full)) do
      "" -> []
      writeup -> ["Full response:", writeup]
    end
  end

  defp full_response_section(_full), do: []

  defp post_section(posts) when is_list(posts) do
    posts
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, index} ->
      ["Post #{index}:", sanitize_multiline(text)]
    end)
  end

  defp link_line(:post_1), do: "(full response) link: Post 1"
  defp link_line(:post_2_link_only), do: "(full response) link: Post 2 (link alone)"

  defp link_line(:post_2_remainder_and_link),
    do: "(full response) link: Post 2 (remainder + link)"

  defp link_line(:post_3_link_only), do: "(full response) link: Post 3 (link alone)"

  defp link_line(:none), do: "(full response) link: none"

  defp one_line(value) when is_binary(value) do
    value
    |> strip_ansi()
    |> String.replace(~r/[\x00-\x1F\x7F-\x9F]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp one_line(_value), do: ""

  defp sanitize_multiline(value) when is_binary(value) do
    value
    |> strip_ansi()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/u, " ")
  end

  defp strip_ansi(value), do: String.replace(value, ~r/\x1B\[[0-?]*[ -\/]*[@-~]/, "")

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
