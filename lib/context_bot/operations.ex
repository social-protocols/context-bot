defmodule ContextBot.Operations do
  @moduledoc """
  Produces bounded credential-free health aggregates and allowlisted structured logs.
  """

  import Ecto.Query

  require Logger

  alias ContextBot.ATProto.Session
  alias ContextBot.Repo
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Settings
  alias ContextBot.Workflow.{Failure, Invocation}

  @terminal_stages [:ineligible, :complete, :failed]
  @active_job_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @attempt_kinds [:eligibility, :thread, :research, :continuation, :repair, :retry, :publication]

  @spec health(keyword()) :: map()
  def health(options \\ []) when is_list(options) do
    config = Keyword.merge(Application.get_env(:context_bot, __MODULE__, []), options)
    now = Keyword.get(config, :now, DateTime.utc_now())
    settings = Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    session_status = Keyword.get(config, :session_status, &Session.status/0)

    aggregates = safe_aggregates(now)

    Map.merge(aggregates, %{
      status: "ok",
      bot: %{
        enabled: Settings.bot_enabled?(settings),
        session: session_state(settings, session_status)
      }
    })
  end

  @spec log_attempt(Invocation.t(), keyword()) :: :ok
  def log_attempt(%Invocation{id: id, stage: stage}, attributes) when is_list(attributes) do
    payload = %{
      invocation_id: id,
      stage: Atom.to_string(stage),
      attempt_kind: safe_attempt_kind(Keyword.get(attributes, :attempt_kind)),
      attempt_index: safe_non_negative(Keyword.get(attributes, :attempt_index)),
      status_code: safe_status_code(Keyword.get(attributes, :status_code)),
      duration_ms: safe_non_negative(Keyword.get(attributes, :duration_ms)),
      failure_category: safe_failure_category(Keyword.get(attributes, :failure_category))
    }

    Logger.info("context_bot_attempt " <> Jason.encode!(payload))
    :ok
  end

  defp safe_aggregates(now) do
    %{
      queues: queue_counts(),
      deferred: deferred_counts(),
      failures: failure_counts(),
      budget: budget_totals(DateTime.to_date(now)),
      oldest_pending_age_seconds: oldest_pending_age(now)
    }
  rescue
    _database_unavailable ->
      %{
        queues: %{},
        deferred: %{},
        failures: %{},
        budget: %{reserved_microdollars: 0, settled_microdollars: 0},
        oldest_pending_age_seconds: nil
      }
  end

  defp queue_counts do
    Oban.Job
    |> where([job], job.state in ^@active_job_states)
    |> group_by([job], job.queue)
    |> select([job], {job.queue, count(job.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp deferred_counts do
    counts =
      Invocation
      |> where(
        [invocation],
        invocation.stage in [:deferred_capacity, :deferred_rate, :deferred_budget]
      )
      |> group_by([invocation], invocation.stage)
      |> select([invocation], {invocation.stage, count(invocation.id)})
      |> Repo.all()
      |> Map.new()

    %{
      "capacity" => Map.get(counts, :deferred_capacity, 0),
      "rate" => Map.get(counts, :deferred_rate, 0),
      "budget" => Map.get(counts, :deferred_budget, 0)
    }
  end

  defp failure_counts do
    Invocation
    |> where(
      [invocation],
      invocation.stage == :failed and not is_nil(invocation.failure_category)
    )
    |> group_by([invocation], invocation.failure_category)
    |> select([invocation], {invocation.failure_category, count(invocation.id)})
    |> Repo.all()
    |> Map.new(fn {category, count} -> {Atom.to_string(category), count} end)
  end

  defp budget_totals(date) do
    BudgetEntry
    |> where([entry], entry.budget_date == ^date)
    |> select([entry], {entry.state, entry.reserved_microdollars, entry.settled_microdollars})
    |> Repo.all()
    |> Enum.reduce(
      %{reserved_microdollars: 0, settled_microdollars: 0},
      fn
        {:settled, _reserved, settled}, totals when is_integer(settled) ->
          Map.update!(totals, :settled_microdollars, &(&1 + settled))

        {_unsettled, reserved, _settled}, totals when is_integer(reserved) ->
          Map.update!(totals, :reserved_microdollars, &(&1 + reserved))
      end
    )
  end

  defp oldest_pending_age(now) do
    oldest =
      Invocation
      |> where([invocation], invocation.stage not in ^@terminal_stages)
      |> select([invocation], min(invocation.received_at))
      |> Repo.one()

    case oldest do
      %DateTime{} = received_at -> max(DateTime.diff(now, received_at, :second), 0)
      nil -> nil
    end
  end

  defp session_state(%Settings{bot_enabled: false}, _status), do: "disabled"

  defp session_state(%Settings{bot_enabled: true}, status) do
    case status.() do
      {:ok, %{authenticated?: true}} -> "authenticated"
      {:ok, %{authenticated?: false}} -> "unauthenticated"
      _unavailable -> "unavailable"
    end
  rescue
    _provider_failure -> "unavailable"
  catch
    :exit, _provider_exit -> "unavailable"
  end

  defp safe_attempt_kind(kind) when kind in @attempt_kinds, do: Atom.to_string(kind)
  defp safe_attempt_kind(_unknown), do: "unknown"

  defp safe_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp safe_non_negative(_invalid), do: nil

  defp safe_status_code(value) when is_integer(value) and value in 100..599, do: value
  defp safe_status_code(_invalid), do: nil

  defp safe_failure_category(nil), do: nil

  defp safe_failure_category(category) do
    category
    |> Failure.category()
    |> Atom.to_string()
  end
end
