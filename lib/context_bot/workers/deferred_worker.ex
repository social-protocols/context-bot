defmodule ContextBot.Workers.DeferredWorker do
  @moduledoc """
  Reconsiders deferred invocations and repairs missing stage jobs oldest-first.

  Candidate claims are short SQLite writes. Oban insertion happens afterward in separate short
  transactions, so a crash between the two is repaired by the next maintenance pass.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias ContextBot.{Admission, Operations, Repo, Settings}
  alias ContextBot.Research.Budget
  alias ContextBot.Workflow.Invocation

  @default_batch_size 25
  @maximum_batch_size 100
  @default_research_claim_lease_ms 21_600_000
  @default_publication_claim_lease_ms 300_000
  @active_job_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    dependencies = dependencies()

    dependencies
    |> claim_batch()
    |> Enum.reduce_while(:ok, fn work, :ok ->
      started_at = System.monotonic_time(:millisecond)
      result = enqueue_once(work)

      Operations.log_attempt(work.invocation_id, work.stage,
        attempt_kind: :maintenance,
        attempt_index: job.attempt,
        duration_ms: System.monotonic_time(:millisecond) - started_at
      )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp claim_batch(dependencies) do
    {:ok, work} =
      Repo.transaction(
        fn ->
          candidates = recovery_candidates(dependencies.batch_size)

          recovery =
            Enum.flat_map(candidates, fn invocation ->
              mark_recovery_checked(invocation, dependencies.now)
              classify_recovery(invocation, dependencies)
            end)

          remaining = dependencies.batch_size - length(recovery)

          {deferred, _remaining_budget} =
            dependencies.now
            |> deferred_candidates(remaining)
            |> Enum.reduce(
              {[], remaining_budget(dependencies.now, dependencies.settings)},
              fn invocation, {work, budget} ->
                {claimed, budget} =
                  claim_candidate(invocation, dependencies.now, dependencies.settings, budget)

                {Enum.reverse(claimed, work), budget}
              end
            )

          recovery ++ Enum.reverse(deferred)
        end,
        mode: :immediate
      )

    work
  end

  defp recovery_candidates(batch_size) do
    batch_size
    |> recovery_query()
    |> Repo.all()
  end

  @doc false
  @spec recovery_query(pos_integer()) :: Ecto.Query.t()
  def recovery_query(batch_size) when is_integer(batch_size) and batch_size > 0 do
    Invocation
    |> where(
      [invocation],
      fragment(
        "? IN ('received', 'checking_eligibility', 'capturing_thread', 'thread_ready', 'researching', 'reply_ready', 'publishing')",
        invocation.stage
      )
    )
    |> order_by(
      [invocation],
      asc: invocation.recovery_checked_at,
      asc: invocation.received_at,
      asc: invocation.id
    )
    |> limit(^batch_size)
  end

  defp mark_recovery_checked(invocation, now) do
    invocation
    |> Invocation.transition_changeset(%{recovery_checked_at: now})
    |> Repo.update!()
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

  defp recovery_work(%Invocation{stage: :received} = invocation),
    do: eligibility_work(invocation)

  defp recovery_work(%Invocation{stage: :checking_eligibility} = invocation),
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

  defp remaining_budget(now, %Settings{anthropic_daily_budget_microdollars: limit})
       when is_integer(limit) and limit > 0,
       do: Budget.remaining(now, limit)

  defp remaining_budget(_now, _settings), do: 0

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
      invocation_id: invocation.id,
      queue: queue,
      stage: invocation.stage,
      worker: worker
    }
  end

  defp classify_recovery(invocation, dependencies) do
    work = recovery_work(invocation)
    classify_target_job(latest_target_job(work), invocation, work, dependencies)
  end

  defp classify_target_job(nil, invocation, work, dependencies) do
    if fresh_lease?(invocation, dependencies), do: [], else: [work]
  end

  defp classify_target_job(
         %Oban.Job{state: state},
         _invocation,
         _work,
         _dependencies
       )
       when state in @active_job_states,
       do: []

  defp classify_target_job(
         %Oban.Job{state: state},
         invocation,
         _work,
         dependencies
       )
       when state in ["cancelled", "discarded"] do
    terminalize_recovery(invocation, "job_#{state}", dependencies.now)
    []
  end

  defp classify_target_job(%Oban.Job{state: "completed"} = job, invocation, work, dependencies),
    do: classify_completed_job(job, invocation, work, dependencies)

  defp classify_target_job(%Oban.Job{}, _invocation, _work, _dependencies), do: []

  defp classify_completed_job(job, invocation, work, dependencies) do
    cond do
      fresh_lease?(invocation, dependencies) ->
        []

      leased_stage?(invocation.stage) ->
        [work]

      invocation.stage == :thread_ready and not is_nil(invocation.deferred_attempt_kind) ->
        [work]

      completed_before_received_transition?(job, invocation) ->
        [work]

      true ->
        terminalize_recovery(invocation, "job_completed_without_handoff", dependencies.now)
        []
    end
  end

  defp completed_before_received_transition?(
         %Oban.Job{completed_at: %DateTime{} = completed_at},
         %Invocation{stage: :received, updated_at: %DateTime{} = transitioned_at}
       ),
       do: DateTime.compare(completed_at, transitioned_at) == :lt

  defp completed_before_received_transition?(_job, _invocation), do: false

  defp latest_target_job(%{args: %{"uri" => uri, "cid" => cid}, worker: worker}) do
    Oban.Job
    |> where(
      [job],
      job.worker == ^worker and
        fragment("json_extract(?, '$.uri')", job.args) == ^uri and
        fragment("json_extract(?, '$.cid')", job.args) == ^cid
    )
    |> order_by([job], desc: job.id)
    |> limit(1)
    |> Repo.one()
  end

  defp fresh_lease?(%Invocation{stage: :researching} = invocation, dependencies) do
    lease_fresh?(
      invocation.research_claim_token,
      invocation.research_claimed_at,
      dependencies.now,
      dependencies.research_claim_lease_ms
    )
  end

  defp fresh_lease?(%Invocation{stage: :publishing} = invocation, dependencies) do
    lease_fresh?(
      invocation.publication_claim_token,
      invocation.publication_claimed_at,
      dependencies.now,
      dependencies.publication_claim_lease_ms
    )
  end

  defp fresh_lease?(_invocation, _dependencies), do: false

  defp lease_fresh?(token, %DateTime{} = claimed_at, now, lease_ms)
       when is_binary(token) and token != "" do
    stale_before = DateTime.add(now, -lease_ms, :millisecond)
    DateTime.compare(claimed_at, stale_before) == :gt
  end

  defp lease_fresh?(_token, _claimed_at, _now, _lease_ms), do: false

  defp leased_stage?(stage), do: stage in [:researching, :publishing]

  defp terminalize_recovery(invocation, reason, now) do
    invocation
    |> Invocation.transition_changeset(%{
      status: :failed,
      stage: :failed,
      failure_category: recovery_failure_category(invocation.stage),
      failure_detail: %{"reason" => reason},
      research_claim_token: nil,
      research_claimed_at: nil,
      publication_claim_token: nil,
      publication_claimed_at: nil,
      completed_at: now
    })
    |> Repo.update!()
  end

  defp recovery_failure_category(stage) when stage in [:received, :checking_eligibility],
    do: :identity_unavailable

  defp recovery_failure_category(:capturing_thread), do: :thread_unavailable

  defp recovery_failure_category(stage) when stage in [:thread_ready, :researching],
    do: :provider_response

  defp recovery_failure_category(_reply_stage), do: :publication_conflict

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
      publication_claim_lease_ms:
        Keyword.get(
          config,
          :publication_claim_lease_ms,
          @default_publication_claim_lease_ms
        ),
      research_claim_lease_ms:
        Keyword.get(config, :research_claim_lease_ms, @default_research_claim_lease_ms),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end

  defp batch_size(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_batch_size)

  defp batch_size(_invalid), do: @default_batch_size
end
