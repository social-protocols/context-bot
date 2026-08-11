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
      {:ok, _summary} -> reconsider_due(workflow: :all, attempt_index: job.attempt)
      {:error, _reason} -> {:error, :recovery_failed}
    end
  end

  @spec reconsider_due(keyword()) :: :ok | {:error, :deferred_reconciliation_failed}
  def reconsider_due(options \\ []) do
    dependencies = dependencies(options)
    workflow = Keyword.get(options, :workflow, :all)
    attempt_index = Keyword.get(options, :attempt_index, 1)

    case reconcile_due(dependencies, workflow, attempt_index) do
      :ok -> :ok
      {:error, _reason} -> {:error, :deferred_reconciliation_failed}
    end
  rescue
    _database_or_state_error -> {:error, :deferred_reconciliation_failed}
  end

  defp reconcile_due(dependencies, :dry_run, attempt_index) do
    boundary_id = dry_boundary_id(dependencies.now)

    drain_dry_pages(
      dependencies,
      attempt_index,
      nil,
      boundary_id,
      :calculate
    )
  end

  defp reconcile_due(dependencies, :all, attempt_index) do
    {work, _remaining_budget, _cursor, _candidate_count} =
      claim_page(
        dependencies,
        :all,
        nil,
        nil,
        :calculate
      )

    process_claimed_work(work, attempt_index, dependencies.enqueue_once)
  end

  defp drain_dry_pages(_dependencies, _attempt_index, _cursor, nil, _remaining_budget),
    do: :ok

  defp drain_dry_pages(
         dependencies,
         attempt_index,
         cursor,
         boundary_id,
         remaining_budget
       ) do
    {work, remaining_budget, next_cursor, candidate_count} =
      claim_page(dependencies, :dry_run, cursor, boundary_id, remaining_budget)

    with :ok <- process_claimed_work(work, attempt_index, dependencies.enqueue_once) do
      if candidate_count == dependencies.batch_size do
        drain_dry_pages(
          dependencies,
          attempt_index,
          next_cursor,
          boundary_id,
          remaining_budget
        )
      else
        :ok
      end
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

  defp process_claimed_work(work, attempt_index, enqueue) do
    Enum.reduce_while(work, :ok, fn claimed, :ok ->
      case process_claim(claimed, attempt_index, enqueue) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp process_claim(work, attempt_index, enqueue) do
    started_at = System.monotonic_time(:millisecond)
    result = enqueue.(work)

    Operations.log_attempt(work.invocation_id, work.stage,
      attempt_kind: :maintenance,
      attempt_index: attempt_index,
      duration_ms: System.monotonic_time(:millisecond) - started_at
    )

    result
  end

  defp claim_page(dependencies, workflow, cursor, boundary_id, remaining_budget) do
    {:ok, page} =
      Repo.transaction(
        fn ->
          remaining_budget = resolve_remaining_budget(remaining_budget, dependencies)

          candidates =
            deferred_candidates(
              dependencies.now,
              dependencies.batch_size,
              workflow,
              cursor,
              boundary_id
            )

          {deferred, remaining_budget} =
            candidates
            |> Enum.reduce(
              {[], remaining_budget},
              fn invocation, {work, budget} ->
                {claimed, budget} =
                  claim_candidate(invocation, dependencies.now, dependencies.settings, budget)

                {Enum.reverse(claimed, work), budget}
              end
            )

          {Enum.reverse(deferred), remaining_budget, candidate_cursor(candidates),
           length(candidates)}
        end,
        mode: :immediate
      )

    page
  end

  @doc false
  @spec recovery_query(pos_integer()) :: Ecto.Query.t()
  defdelegate recovery_query(batch_size), to: Recovery, as: :candidate_query

  defp deferred_candidates(now, limit, workflow, cursor, boundary_id) do
    Invocation
    |> due_candidates(now, workflow)
    |> after_cursor(cursor)
    |> before_boundary(boundary_id)
    |> order_by([invocation], asc: invocation.received_at, asc: invocation.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp due_candidates(query, now, :dry_run) do
    where(
      query,
      [invocation],
      invocation.dry_run and invocation.stage == :deferred_budget and
        not is_nil(invocation.defer_until) and invocation.defer_until <= ^now
    )
  end

  defp due_candidates(query, now, :all) do
    where(
      query,
      [invocation],
      invocation.stage == :deferred_capacity or
        (invocation.stage in [:deferred_rate, :deferred_budget] and
           not is_nil(invocation.defer_until) and invocation.defer_until <= ^now)
    )
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {received_at, id}) do
    where(
      query,
      [invocation],
      invocation.received_at > ^received_at or
        (invocation.received_at == ^received_at and invocation.id > ^id)
    )
  end

  defp before_boundary(query, nil), do: query

  defp before_boundary(query, boundary_id),
    do: where(query, [invocation], invocation.id <= ^boundary_id)

  defp dry_boundary_id(now) do
    Invocation
    |> due_candidates(now, :dry_run)
    |> select([invocation], max(invocation.id))
    |> Repo.one()
  end

  defp candidate_cursor([]), do: nil

  defp candidate_cursor(candidates) do
    candidate = List.last(candidates)
    {candidate.received_at, candidate.id}
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

    if accepted_workflow?(invocation, now, settings) and reservation <= remaining_budget do
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

  defp accepted_workflow?(%Invocation{dry_run: true} = invocation, _now, _settings),
    do: durable_thread?(invocation)

  defp accepted_workflow?(invocation, now, settings) do
    is_binary(invocation.eligibility_method) and invocation.eligibility_method != "" and
      is_map(invocation.eligibility_evidence) and map_size(invocation.eligibility_evidence) > 0 and
      match?(%DateTime{}, invocation.admitted_at) and durable_thread?(invocation) and
      Admission.resume_available?(invocation, now, settings)
  end

  defp durable_thread?(invocation),
    do:
      is_binary(invocation.canonical_thread) and invocation.canonical_thread != "" and
        is_binary(invocation.current_cid) and invocation.current_cid != ""

  defp resolve_remaining_budget(:calculate, dependencies) do
    case dependencies.settings do
      %Settings{anthropic_daily_budget_microdollars: limit}
      when is_integer(limit) and limit > 0 ->
        dependencies.remaining_budget.(dependencies.now, limit)

      _missing_budget ->
        0
    end
  end

  defp resolve_remaining_budget(remaining_budget, _dependencies), do: remaining_budget

  defp eligibility_work(invocation),
    do: work(invocation, "ContextBot.Workers.EligibilityWorker", :eligibility)

  defp research_work(invocation),
    do: work(invocation, "ContextBot.Workers.ResearchWorker", research_queue(invocation))

  defp research_queue(%Invocation{dry_run: true}), do: :dry_research
  defp research_queue(%Invocation{}), do: :research

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

  defp dependencies(options \\ []) do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      batch_size:
        batch_size(
          Keyword.get(options, :batch_size, Keyword.get(config, :batch_size, @default_batch_size))
        ),
      now: Keyword.get(options, :now, Keyword.get(config, :now, DateTime.utc_now())),
      recovery: Keyword.get(options, :recovery, Keyword.get(config, :recovery, Recovery)),
      enqueue_once: Keyword.get(config, :enqueue_once, &enqueue_once/1),
      remaining_budget: Keyword.get(config, :remaining_budget, &Budget.remaining/2),
      settings:
        Keyword.get(
          options,
          :settings,
          Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
        )
    }
  end

  defp batch_size(value) when is_integer(value) and value > 0,
    do: min(value, @maximum_batch_size)

  defp batch_size(_invalid), do: @default_batch_size
end
