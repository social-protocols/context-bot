defmodule ContextBot.Workers.DeferredWorker do
  @moduledoc """
  Reconsiders deferred invocations after running shared orphan recovery.

  Candidate claims are short SQLite writes. Oban insertion happens afterward in separate short
  transactions, so a crash between the two is repaired by the next maintenance pass.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias ContextBot.{Admission, Operations, Repo, Settings}
  alias ContextBot.Research.Budget
  alias ContextBot.Workflow.{Invocation, Recovery}

  @default_batch_size 25
  @maximum_batch_size 100
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    dependencies = dependencies()

    case recover(dependencies) do
      {:ok, _summary} -> process_claimed_work(claim_batch(dependencies), job)
      {:error, _reason} -> {:error, :recovery_failed}
    end
  end

  defp recover(dependencies) do
    dependencies.recovery.recover_orphans(
      now: dependencies.now,
      startup?: false,
      settings: dependencies.settings,
      batch_size: dependencies.batch_size
    )
  end

  defp process_claimed_work(work, job) do
    Enum.reduce_while(work, :ok, fn claimed, :ok ->
      case process_claim(claimed, job) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp process_claim(work, job) do
    started_at = System.monotonic_time(:millisecond)
    result = enqueue_once(work)

    Operations.log_attempt(work.invocation_id, work.stage,
      attempt_kind: :maintenance,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at
    )

    result
  end

  defp claim_batch(dependencies) do
    {:ok, work} =
      Repo.transaction(
        fn ->
          {deferred, _remaining_budget} =
            dependencies.now
            |> deferred_candidates(dependencies.batch_size)
            |> Enum.reduce(
              {[], remaining_budget(dependencies.now, dependencies.settings)},
              fn invocation, {work, budget} ->
                {claimed, budget} =
                  claim_candidate(invocation, dependencies.now, dependencies.settings, budget)

                {Enum.reverse(claimed, work), budget}
              end
            )

          Enum.reverse(deferred)
        end,
        mode: :immediate
      )

    work
  end

  @doc false
  @spec recovery_query(pos_integer()) :: Ecto.Query.t()
  defdelegate recovery_query(batch_size), to: Recovery, as: :candidate_query

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

  defp claim_candidate(
         %Invocation{stage: :deferred_capacity} = invocation,
         _now,
         settings,
         remaining_budget
       ) do
    if Admission.capacity_available?(settings, invocation.id) do
      work =
        invocation
        |> move_to(:received, %{
          eligibility_method: nil,
          eligibility_evidence: nil,
          defer_until: nil
        })
        |> eligibility_work()
        |> List.wrap()

      {work, remaining_budget}
    else
      {[], remaining_budget}
    end
  end

  defp claim_candidate(
         %Invocation{stage: :deferred_rate} = invocation,
         _now,
         settings,
         remaining_budget
       ) do
    if Admission.capacity_available?(settings, invocation.id) do
      work =
        invocation
        |> move_to(:received, %{
          eligibility_method: nil,
          eligibility_evidence: nil,
          defer_until: nil
        })
        |> eligibility_work()
        |> List.wrap()

      {work, remaining_budget}
    else
      {[], remaining_budget}
    end
  end

  defp claim_candidate(
         %Invocation{stage: :deferred_budget} = invocation,
         now,
         settings,
         remaining_budget
       ) do
    attempt_kind = invocation.deferred_attempt_kind || :research
    reservation = Settings.anthropic_reservation_microdollars(settings, attempt_kind)

    if accepted_workflow?(invocation) and Admission.resume_available?(invocation, now, settings) and
         reservation <= remaining_budget do
      work =
        invocation
        |> move_to(:thread_ready, %{
          defer_until: nil,
          deferred_attempt_kind: attempt_kind
        })
        |> research_work()
        |> List.wrap()

      {work, remaining_budget - reservation}
    else
      {[], remaining_budget}
    end
  end

  defp claim_candidate(%Invocation{}, _now, _settings, remaining_budget),
    do: {[], remaining_budget}

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

  defp remaining_budget(now, %Settings{anthropic_daily_budget_microdollars: limit})
       when is_integer(limit) and limit > 0,
       do: Budget.remaining(now, limit)

  defp remaining_budget(_now, _settings), do: 0

  defp eligibility_work(invocation),
    do: work(invocation, "ContextBot.Workers.EligibilityWorker", :eligibility)

  defp research_work(invocation),
    do: work(invocation, "ContextBot.Workers.ResearchWorker", :research)

  defp work(invocation, worker, queue) do
    %{
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      invocation_id: invocation.id,
      queue: queue,
      stage: invocation.stage,
      worker: worker
    }
  end

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
      recovery: Keyword.get(config, :recovery, Recovery),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end

  defp batch_size(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_batch_size)

  defp batch_size(_invalid), do: @default_batch_size
end
