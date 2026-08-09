defmodule Mix.Tasks.ContextBot.DryRun do
  @moduledoc "Runs one durable, local-only context check against a public Bluesky post."

  use Mix.Task

  import Ecto.Query

  alias ContextBot.{DryRun, Repo, Settings}
  alias ContextBot.Research.BudgetEntry

  @requirements ["app.start"]
  @shortdoc "Run a durable local context check without posting to Bluesky"

  @impl Mix.Task
  def run([post, question]) do
    config = Application.get_env(:context_bot, __MODULE__, [])
    service = Keyword.get(config, :service, DryRun)
    runtime = Keyword.get(config, :runtime, ContextBot.DryRun.Runtime)
    settled_cost = Keyword.get(config, :settled_cost, &settled_cost/1)
    settings = Application.fetch_env!(:context_bot, :settings)

    validate_runtime!(settings)
    ensure_runtime!(runtime)

    invocation = create!(service, post, question)

    case service.await(invocation) do
      {:ok, settled} ->
        print_complete(settled, settled_cost.(settled))
        :ok

      {:deferred, deferred} ->
        Mix.shell().info("dry_run_id=#{deferred.id}")
        Mix.raise("dry run deferred by the configured Anthropic daily budget")

      {:error, %ContextBot.Workflow.Invocation{} = failed} ->
        Mix.shell().info("dry_run_id=#{failed.id}")
        Mix.raise("dry run failed at stage=#{failed.stage}")

      {:error, reason} when is_atom(reason) ->
        Mix.raise("dry run did not settle: #{reason}")
    end
  end

  def run(_arguments), do: Mix.raise("expected exactly a post and question")

  defp validate_runtime!(settings) do
    if Settings.bot_enabled?(settings), do: Mix.raise("dry run requires BOT_ENABLED=false")

    unless is_integer(settings.anthropic_daily_budget_microdollars) and
             settings.anthropic_daily_budget_microdollars > 0 do
      Mix.raise("ANTHROPIC_DAILY_BUDGET_USD is required for a dry run")
    end

    case Application.get_env(:context_bot, :anthropic_api_key) do
      key when is_binary(key) and key != "" -> :ok
      _missing -> Mix.raise("ANTHROPIC_API_KEY is required for a dry run")
    end
  end

  defp ensure_runtime!(runtime) do
    case runtime.ensure_started() do
      :ok -> :ok
      {:error, reason} -> Mix.raise("unable to start safe dry-run workers: #{reason}")
    end
  end

  defp create!(service, post, question) do
    case service.create(post, question, []) do
      {:ok, invocation} -> invocation
      {:error, reason} when is_atom(reason) -> Mix.raise("unable to create dry run: #{reason}")
    end
  end

  defp print_complete(invocation, cost_microdollars) do
    totals = get_in(invocation.anthropic_usage || %{}, ["totals"]) || %{}

    Mix.shell().info("dry_run_id=#{invocation.id}")
    Mix.shell().info("status=complete")
    Mix.shell().info("answer=#{one_line(invocation.selected_reply)}")

    Mix.shell().info(
      "usage input_tokens=#{integer(totals["input_tokens"])} " <>
        "output_tokens=#{integer(totals["output_tokens"])} " <>
        "tool_uses=#{integer((invocation.anthropic_usage || %{})["tool_uses"])} " <>
        "cost_microdollars=#{integer(cost_microdollars)}"
    )
  end

  defp settled_cost(invocation) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation.id)
    |> select([entry], entry.settled_microdollars)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp one_line(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp one_line(_value), do: ""

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0
end
