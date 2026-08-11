defmodule ContextBot.Workflow.Recovery do
  @moduledoc """
  Reconciles abandoned workflow jobs from durable SQLite state.

  Provider-exposed research is never replayed unless its complete response envelope was already
  committed. Dry and public invocations always remain on their respective queues.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{Budget, BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workflow.Invocation

  @candidate_stages [
    :received,
    :checking_eligibility,
    :capturing_thread,
    :thread_ready,
    :researching,
    :reply_ready,
    :publishing
  ]
  @active_job_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @runtime_orphan_states ["executing", "completed", "cancelled", "discarded"]
  @default_batch_size 100
  @maximum_batch_size 100
  @research_claim_lease_ms 21_600_000
  @publication_claim_lease_ms 300_000
  @http_grace_ms 30_000

  @type result :: :resumed | :terminalized | :unchanged

  @spec recover_orphans(keyword()) ::
          {:ok,
           %{
             examined: non_neg_integer(),
             resumed: non_neg_integer(),
             terminalized: non_neg_integer(),
             unchanged: non_neg_integer()
           }}
          | {:error, :recovery_failed}
  def recover_orphans(options \\ []) when is_list(options) do
    config = config(options)

    if config.workflow == :dry_run do
      recover_dry_pages(config, options)
    else
      config.batch_size
      |> candidate_query()
      |> Repo.all()
      |> recover_candidates(options)
    end
  rescue
    _database_or_state_error -> {:error, :recovery_failed}
  end

  defp recover_dry_pages(config, options) do
    boundary_id = dry_boundary_id()
    drain_dry_pages(nil, boundary_id, config, options, empty_summary())
  end

  defp drain_dry_pages(_cursor, nil, _config, _options, summary), do: {:ok, summary}

  defp drain_dry_pages(cursor, boundary_id, config, options, summary) do
    candidates =
      config.batch_size
      |> dry_candidate_query(cursor, boundary_id)
      |> Repo.all()

    {:ok, page_summary} = recover_candidates(candidates, options)
    summary = merge_summary(summary, page_summary)

    if length(candidates) == config.batch_size do
      drain_dry_pages(List.last(candidates).id, boundary_id, config, options, summary)
    else
      {:ok, summary}
    end
  end

  defp recover_candidates(candidates, options) do
    summary = %{empty_summary() | examined: length(candidates)}

    recovered =
      Enum.reduce(candidates, summary, fn invocation, counts ->
        case recover_invocation(invocation, options) do
          :resumed -> Map.update!(counts, :resumed, &(&1 + 1))
          :terminalized -> Map.update!(counts, :terminalized, &(&1 + 1))
          :unchanged -> Map.update!(counts, :unchanged, &(&1 + 1))
        end
      end)

    {:ok, recovered}
  end

  defp empty_summary,
    do: %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}

  defp merge_summary(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end

  @doc false
  @spec candidate_query(pos_integer()) :: Ecto.Query.t()
  def candidate_query(batch_size) when is_integer(batch_size) and batch_size > 0 do
    Invocation
    |> candidate_stages()
    |> order_by(
      [invocation],
      asc: invocation.recovery_checked_at,
      asc: invocation.received_at,
      asc: invocation.id
    )
    |> limit(^batch_size)
  end

  defp dry_candidate_query(batch_size, cursor, boundary_id) do
    Invocation
    |> candidate_stages()
    |> where([invocation], invocation.dry_run and invocation.id <= ^boundary_id)
    |> after_id(cursor)
    |> order_by([invocation], asc: invocation.id)
    |> limit(^batch_size)
  end

  defp candidate_stages(query) do
    where(
      query,
      [invocation],
      fragment(
        "? IN ('received', 'checking_eligibility', 'capturing_thread', 'thread_ready', 'researching', 'reply_ready', 'publishing')",
        invocation.stage
      )
    )
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [invocation], invocation.id > ^id)

  defp dry_boundary_id do
    Invocation
    |> candidate_stages()
    |> where([invocation], invocation.dry_run)
    |> select([invocation], max(invocation.id))
    |> Repo.one()
  end

  @spec recover_invocation(Invocation.t(), keyword()) :: result()
  def recover_invocation(%Invocation{id: id}, options \\ []) when is_list(options) do
    config = config(options)

    {:ok, result} =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, id)
          recover_locked(invocation, config)
        end,
        mode: :immediate
      )

    result
  end

  defp recover_locked(%Invocation{stage: stage}, _config) when stage not in @candidate_stages,
    do: :unchanged

  defp recover_locked(%Invocation{} = invocation, config) do
    case work_for(invocation) do
      invalid when invalid in [:invalid_dry_prethread, :invalid_dry_publication] ->
        worker =
          if invalid == :invalid_dry_prethread,
            do: "ContextBot.Workers.EligibilityWorker",
            else: "ContextBot.Workers.ReplyWorker"

        job = latest_job(invocation, worker)

        if orphaned?(invocation, job, config) do
          terminalize(
            invocation,
            job,
            :publication_conflict,
            Atom.to_string(invalid),
            config.now
          )
        else
          :unchanged
        end

      work ->
        job = latest_job(invocation, work.worker)

        if orphaned?(invocation, job, config) do
          recover_stage(invocation, job, work, config)
        else
          mark_checked(invocation, config.now)
          :unchanged
        end
    end
  end

  defp recover_stage(%Invocation{stage: stage} = invocation, job, work, config)
       when stage in [:thread_ready, :researching] do
    case Budget.unrecorded_exposed_attempt(invocation) do
      %BudgetEntry{} = entry ->
        mark_budget_indeterminate(entry)
        terminalize(invocation, job, :provider_response, "interrupted_after_send", config.now)

      nil ->
        recover_safe_research(invocation, job, work, config)
    end
  end

  defp recover_stage(%Invocation{stage: stage} = invocation, job, work, config)
       when stage in [:reply_ready, :publishing] do
    invocation
    |> Invocation.transition_changeset(%{
      status: :reply_ready,
      stage: :reply_ready,
      publication_claim_token: nil,
      publication_claimed_at: nil,
      recovery_checked_at: config.now
    })
    |> Repo.update!()

    make_available(job, invocation, work, config.now)
    :resumed
  end

  defp recover_stage(%Invocation{} = invocation, job, work, config) do
    mark_checked(invocation, config.now)
    make_available(job, invocation, work, config.now)
    :resumed
  end

  defp recover_safe_research(invocation, job, work, config) do
    case latest_budget_entry(invocation) do
      %BudgetEntry{state: state} = entry when state in [:sent, :indeterminate] ->
        if response_envelope?(entry) do
          resume_research(invocation, job, work, config.now)
        else
          mark_budget_indeterminate(entry)
          terminalize(invocation, job, :provider_response, "interrupted_after_send", config.now)
        end

      _safe_or_unexposed ->
        resume_research(invocation, job, work, config.now)
    end
  end

  defp orphaned?(%Invocation{stage: stage} = invocation, nil, config)
       when stage in [:researching, :publishing],
       do: not fresh_lease?(invocation, nil, config)

  defp orphaned?(_invocation, nil, _config), do: true

  defp orphaned?(invocation, %Oban.Job{state: state} = job, config) do
    cond do
      state not in config.job_states ->
        false

      config.startup? ->
        state == "executing"

      state == "executing" ->
        not fresh_lease?(invocation, job, config)

      state in @active_job_states and state != "executing" ->
        false

      invocation.stage in [:researching, :publishing] ->
        not fresh_lease?(invocation, job, config)

      true ->
        true
    end
  end

  defp fresh_lease?(
         %Invocation{stage: :researching, research_claimed_at: claimed_at},
         _job,
         config
       ),
       do: timestamp_fresh?(claimed_at, config.now, @research_claim_lease_ms)

  defp fresh_lease?(
         %Invocation{stage: :publishing, publication_claimed_at: claimed_at},
         _job,
         config
       ),
       do: timestamp_fresh?(claimed_at, config.now, @publication_claim_lease_ms)

  defp fresh_lease?(%Invocation{stage: stage} = invocation, job, config)
       when stage in [:received, :checking_eligibility] do
    timeout =
      max(config.settings.atproto_http_timeout_ms, config.settings.atproto_session_timeout_ms) +
        @http_grace_ms

    timestamp_fresh?(attempted_at(job) || invocation.updated_at, config.now, timeout)
  end

  defp fresh_lease?(%Invocation{stage: :capturing_thread} = invocation, job, config) do
    timeout = config.settings.thread_fetch_timeout_ms + @http_grace_ms
    timestamp_fresh?(attempted_at(job) || invocation.updated_at, config.now, timeout)
  end

  defp fresh_lease?(_invocation, _job, _config), do: false

  defp timestamp_fresh?(%DateTime{} = timestamp, now, lease_ms) do
    DateTime.compare(timestamp, DateTime.add(now, -lease_ms, :millisecond)) == :gt
  end

  defp timestamp_fresh?(_timestamp, _now, _lease_ms), do: false

  defp attempted_at(%Oban.Job{attempted_at: %DateTime{} = attempted_at}), do: attempted_at
  defp attempted_at(_job), do: nil

  defp work_for(%Invocation{stage: stage, dry_run: dry_run})
       when stage in [:received, :checking_eligibility] and not dry_run,
       do: %{worker: "ContextBot.Workers.EligibilityWorker", queue: :eligibility}

  defp work_for(%Invocation{stage: stage, dry_run: true})
       when stage in [:received, :checking_eligibility],
       do: :invalid_dry_prethread

  defp work_for(%Invocation{stage: :capturing_thread, dry_run: dry_run}),
    do: %{
      worker: "ContextBot.Workers.ThreadWorker",
      queue: if(dry_run, do: :dry_thread, else: :thread)
    }

  defp work_for(%Invocation{stage: stage, dry_run: dry_run})
       when stage in [:thread_ready, :researching],
       do: %{
         worker: "ContextBot.Workers.ResearchWorker",
         queue: if(dry_run, do: :dry_research, else: :research)
       }

  defp work_for(%Invocation{stage: stage, dry_run: false})
       when stage in [:reply_ready, :publishing],
       do: %{worker: "ContextBot.Workers.ReplyWorker", queue: :reply}

  defp work_for(%Invocation{stage: stage, dry_run: true})
       when stage in [:reply_ready, :publishing],
       do: :invalid_dry_publication

  defp latest_job(invocation, worker) do
    Oban.Job
    |> where(
      [job],
      job.worker == ^worker and
        fragment("json_extract(?, '$.uri')", job.args) == ^invocation.invocation_uri and
        fragment("json_extract(?, '$.cid')", job.args) == ^invocation.notification_cid
    )
    |> order_by([job], desc: job.id)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_budget_entry(invocation) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation.id)
    |> order_by([entry], desc: entry.id)
    |> limit(1)
    |> Repo.one()
  end

  defp response_envelope?(entry) do
    Repo.exists?(from envelope in ResponseEnvelope, where: envelope.budget_entry_id == ^entry.id)
  end

  defp resume_research(invocation, job, work, now) do
    invocation
    |> Invocation.transition_changeset(%{
      status: :thread_ready,
      stage: :thread_ready,
      research_claim_token: nil,
      research_claimed_at: nil,
      recovery_checked_at: now
    })
    |> Repo.update!()

    make_available(job, invocation, work, now)
    :resumed
  end

  defp mark_budget_indeterminate(%BudgetEntry{state: :sent} = entry) do
    entry
    |> BudgetEntry.changeset(%{state: :indeterminate, settled_microdollars: nil})
    |> Repo.update!()
  end

  defp mark_budget_indeterminate(%BudgetEntry{state: :indeterminate}), do: :ok

  defp terminalize(invocation, job, category, reason, now) do
    invocation
    |> Invocation.transition_changeset(%{
      status: :failed,
      stage: :failed,
      failure_category: category,
      failure_detail: %{"reason" => reason},
      research_claim_token: nil,
      research_claimed_at: nil,
      publication_claim_token: nil,
      publication_claimed_at: nil,
      recovery_checked_at: now,
      completed_at: now
    })
    |> Repo.update!()

    discard(job, now)
    :terminalized
  end

  defp mark_checked(invocation, now) do
    invocation
    |> Invocation.transition_changeset(%{recovery_checked_at: now})
    |> Repo.update!()
  end

  defp make_available(nil, invocation, work, _now) do
    %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
    |> Oban.Job.new(
      worker: work.worker,
      queue: work.queue,
      unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]
    )
    |> Repo.insert!()
  end

  defp make_available(%Oban.Job{state: state}, invocation, work, now)
       when state not in @active_job_states,
       do: make_available(nil, invocation, work, now)

  defp make_available(job, _invocation, work, now) do
    job
    |> Ecto.Changeset.change(%{
      state: "available",
      queue: Atom.to_string(work.queue),
      scheduled_at: now,
      attempted_at: nil,
      attempted_by: [],
      cancelled_at: nil,
      completed_at: nil,
      discarded_at: nil
    })
    |> Repo.update!()
  end

  defp discard(nil, _now), do: :ok

  defp discard(job, now) do
    job
    |> Ecto.Changeset.change(%{state: "discarded", discarded_at: now})
    |> Repo.update!()
  end

  defp config(options) do
    startup? = Keyword.get(options, :startup?, false)

    %{
      batch_size:
        options
        |> Keyword.get(:batch_size, @default_batch_size)
        |> min(@maximum_batch_size)
        |> max(1),
      job_states:
        Keyword.get(
          options,
          :job_states,
          if(startup?, do: ["executing"], else: @runtime_orphan_states)
        ),
      now: Keyword.get(options, :now, DateTime.utc_now()),
      settings: Keyword.get(options, :settings, Application.fetch_env!(:context_bot, :settings)),
      startup?: startup?,
      workflow: Keyword.get(options, :workflow, :all)
    }
  end
end
