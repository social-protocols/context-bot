defmodule ContextBot.Workers.DeferredWorker do
  @moduledoc """
  Reconsiders deferred invocations and repairs missing stage jobs oldest-first.

  Candidate claims are short SQLite writes. Oban insertion happens afterward in separate short
  transactions, so a crash between the two is repaired by the next maintenance pass.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias ContextBot.{Admission, Repo, Settings}
  alias ContextBot.Research.Budget
  alias ContextBot.Workflow.Invocation

  @default_batch_size 25
  @maximum_batch_size 100
  @active_job_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @workflow_workers [
    "ContextBot.Workers.EligibilityWorker",
    "ContextBot.Workers.ThreadWorker",
    "ContextBot.Workers.ResearchWorker",
    "ContextBot.Workers.ReplyWorker"
  ]
  @recovery_stages [
    :received,
    :capturing_thread,
    :thread_ready,
    :researching,
    :reply_ready,
    :publishing
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    dependencies = dependencies()

    dependencies.now
    |> claim_batch(dependencies.settings, dependencies.batch_size)
    |> Enum.reduce_while(:ok, fn work, :ok ->
      case enqueue_once(work) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp claim_batch(now, settings, batch_size) do
    {:ok, work} =
      Repo.transaction(
        fn ->
          active_keys = active_work_keys()
          recovery = missing_recovery(batch_size, active_keys)
          remaining = batch_size - length(recovery)

          deferred =
            now
            |> deferred_candidates(remaining)
            |> Enum.flat_map(&claim_candidate(&1, now, settings))

          recovery ++ deferred
        end,
        mode: :immediate
      )

    work
  end

  defp missing_recovery(batch_size, active_keys) do
    Invocation
    |> where([invocation], invocation.stage in ^@recovery_stages)
    |> order_by([invocation], asc: invocation.received_at, asc: invocation.id)
    |> limit(^(batch_size + MapSet.size(active_keys)))
    |> Repo.all()
    |> Enum.map(&recovery_work/1)
    |> Enum.reject(&(work_key(&1) in active_keys))
    |> Enum.take(batch_size)
  end

  defp deferred_candidates(_now, remaining) when remaining <= 0, do: []

  defp deferred_candidates(now, remaining) do
    Invocation
    |> where(
      [invocation],
      invocation.stage == :deferred_capacity or
        (invocation.stage in [:deferred_rate, :deferred_budget] and
           not is_nil(invocation.defer_until) and invocation.defer_until <= ^now)
    )
    |> order_by([invocation], asc: invocation.received_at, asc: invocation.id)
    |> limit(^remaining)
    |> Repo.all()
  end

  defp active_work_keys do
    Oban.Job
    |> where(
      [job],
      job.state in ^@active_job_states and job.worker in ^@workflow_workers
    )
    |> select([job], {job.worker, job.args})
    |> Repo.all()
    |> MapSet.new(fn {worker, args} ->
      {worker, Map.get(args, "uri"), Map.get(args, "cid")}
    end)
  end

  defp claim_candidate(%Invocation{stage: :deferred_capacity} = invocation, _now, settings) do
    if Admission.capacity_available?(settings, invocation.id) do
      invocation
      |> move_to(:received, %{
        eligibility_method: nil,
        eligibility_evidence: nil,
        defer_until: nil
      })
      |> eligibility_work()
      |> List.wrap()
    else
      []
    end
  end

  defp claim_candidate(%Invocation{stage: :deferred_rate} = invocation, _now, _settings) do
    invocation
    |> move_to(:received, %{
      eligibility_method: nil,
      eligibility_evidence: nil,
      defer_until: nil
    })
    |> eligibility_work()
    |> List.wrap()
  end

  defp claim_candidate(%Invocation{stage: :deferred_budget} = invocation, now, settings) do
    if accepted_workflow?(invocation) and Admission.resume_available?(invocation, now, settings) and
         budget_available?(now, settings) do
      invocation
      |> move_to(:thread_ready, %{defer_until: nil})
      |> research_work()
      |> List.wrap()
    else
      []
    end
  end

  defp claim_candidate(%Invocation{}, _now, _settings), do: []

  defp recovery_work(%Invocation{stage: :received} = invocation),
    do: eligibility_work(invocation)

  defp recovery_work(%Invocation{stage: :capturing_thread} = invocation),
    do: thread_work(invocation)

  defp recovery_work(%Invocation{stage: stage} = invocation)
       when stage in [:thread_ready, :researching],
       do: research_work(invocation)

  defp recovery_work(%Invocation{stage: stage} = invocation)
       when stage in [:reply_ready, :publishing],
       do: reply_work(invocation)

  defp move_to(invocation, stage, attrs) do
    invocation
    |> Invocation.transition_changeset(
      attrs
      |> Map.put(:status, stage)
      |> Map.put(:stage, stage)
    )
    |> Repo.update!()
  end

  defp accepted_workflow?(invocation) do
    is_binary(invocation.eligibility_method) and invocation.eligibility_method != "" and
      is_map(invocation.eligibility_evidence) and map_size(invocation.eligibility_evidence) > 0 and
      match?(%DateTime{}, invocation.admitted_at) and is_binary(invocation.canonical_thread) and
      invocation.canonical_thread != "" and is_binary(invocation.current_cid) and
      invocation.current_cid != ""
  end

  defp budget_available?(now, %Settings{anthropic_daily_budget_microdollars: limit} = settings)
       when is_integer(limit) and limit > 0 do
    minimum_reservation =
      [:research, :continuation, :repair, :retry]
      |> Enum.map(&Settings.anthropic_reservation_microdollars(settings, &1))
      |> Enum.min()

    Budget.remaining(now, limit) >= minimum_reservation
  end

  defp budget_available?(_now, _settings), do: false

  defp eligibility_work(invocation),
    do: work(invocation, "ContextBot.Workers.EligibilityWorker", :eligibility)

  defp thread_work(invocation),
    do: work(invocation, "ContextBot.Workers.ThreadWorker", :thread)

  defp research_work(invocation),
    do: work(invocation, "ContextBot.Workers.ResearchWorker", :research)

  defp reply_work(invocation),
    do: work(invocation, "ContextBot.Workers.ReplyWorker", :reply)

  defp work(invocation, worker, queue) do
    %{
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      queue: queue,
      worker: worker
    }
  end

  defp work_key(%{args: args, worker: worker}),
    do: {worker, Map.get(args, "uri"), Map.get(args, "cid")}

  defp enqueue_once(%{args: args, queue: queue, worker: worker}) do
    changeset =
      Oban.Job.new(args,
        worker: worker,
        queue: queue,
        unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]
      )

    oban_config =
      :context_bot
      |> Application.fetch_env!(Oban)
      |> Oban.Config.new()

    result =
      Repo.transaction(
        fn -> Oban.Engine.insert_job(oban_config, changeset, []) end,
        mode: :immediate
      )

    case result do
      {:ok, {:ok, %Oban.Job{}}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dependencies do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      batch_size: batch_size(Keyword.get(config, :batch_size, @default_batch_size)),
      now: Keyword.get(config, :now, DateTime.utc_now()),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end

  defp batch_size(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_batch_size)

  defp batch_size(_invalid), do: @default_batch_size
end
