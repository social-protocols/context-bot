defmodule ContextBot.Workers.DeferredWorkerTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Settings
  alias ContextBot.Workers.DeferredWorker
  alias ContextBot.Workflow.Invocation
  alias Ecto.Adapters.SQL

  @now ~U[2026-07-31 00:00:01.000000Z]
  @rollover ~U[2026-07-31 00:00:00.000000Z]
  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"

  defmodule FakeRecovery do
    def recover_orphans(options) do
      send(Process.get(:recovery_test_pid), {:recover_orphans, options})
      {:ok, %{examined: 0, resumed: 0, terminalized: 0, unchanged: 0}}
    end
  end

  setup do
    Process.put(:recovery_test_pid, self())
    previous = Application.get_env(:context_bot, DeferredWorker)

    on_exit(fn ->
      Process.delete(:recovery_test_pid)

      if previous do
        Application.put_env(:context_bot, DeferredWorker, previous)
      else
        Application.delete_env(:context_bot, DeferredWorker)
      end
    end)

    :ok
  end

  test "delegates orphan reconciliation to the shared recovery coordinator" do
    configured_settings = settings()
    configure(recovery: FakeRecovery, settings: configured_settings, batch_size: 7)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert_receive {:recover_orphans, options}
    assert options[:startup?] == false
    assert options[:now] == @now
    assert options[:settings] == configured_settings
    assert options[:batch_size] == 7
  end

  test "maintenance terminalizes stale sent research without replaying the provider call" do
    invocation =
      invocation("ambiguous-research", :researching,
        minutes_ago: 400,
        canonical_thread: "ancestor context",
        canonical_thread_version: "1",
        research_claim_token: "abandoned-owner",
        research_claimed_at: DateTime.add(@now, -21_600_001, :millisecond)
      )

    job = executing_job(invocation, "ContextBot.Workers.ResearchWorker", :research)

    entry =
      %BudgetEntry{}
      |> BudgetEntry.changeset(%{
        attempt_key: "maintenance-ambiguous-research",
        invocation_id: invocation.id,
        budget_date: DateTime.to_date(@now),
        kind: :research,
        reserved_microdollars: 5_000_000,
        state: :sent,
        sent_at: DateTime.add(@now, -21_600_001, :millisecond),
        research_claim_token: "abandoned-owner"
      })
      |> Repo.insert!()

    configure()
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_detail == %{"reason" => "interrupted_after_send"}
    assert Repo.reload!(entry).state == :indeterminate
    assert Repo.reload!(job).state == "discarded"
    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "reconsiders a bounded oldest-first batch and leaves future deferrals untouched" do
    oldest = invocation("oldest-capacity", :deferred_capacity, minutes_ago: 5)

    second =
      invocation("second-rate", :deferred_rate,
        minutes_ago: 4,
        defer_until: DateTime.add(@now, -1, :second),
        eligibility_method: "bluesky_elder",
        eligibility_evidence: %{"label" => "bluesky-elder"}
      )

    third = accepted_budget_invocation("third-budget", minutes_ago: 3)

    future =
      invocation("future-rate", :deferred_rate,
        minutes_ago: 6,
        defer_until: DateTime.add(@now, 60, :second)
      )

    configure(batch_size: 2)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    jobs = Repo.all(from job in Oban.Job, order_by: [asc: job.id])

    assert Enum.map(jobs, &{&1.worker, &1.args}) == [
             {"ContextBot.Workers.EligibilityWorker", job_args(oldest)},
             {"ContextBot.Workers.EligibilityWorker", job_args(second)}
           ]

    assert Repo.reload!(oldest).stage == :received
    assert Repo.reload!(second).stage == :received
    assert Repo.reload!(second).eligibility_method == nil
    assert Repo.reload!(second).eligibility_evidence == nil
    assert Repo.reload!(third).stage == :deferred_budget
    assert Repo.reload!(future).stage == :deferred_rate
  end

  test "capacity is rechecked while excluding the deferred invocation itself" do
    blocker = invocation("capacity-blocker", :received, minutes_ago: 3)
    deferred = invocation("capacity-waiter", :deferred_capacity, minutes_ago: 2)
    configure(settings: settings(max_pending: 1))

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(deferred).stage == :deferred_capacity

    assert [%Oban.Job{args: blocker_args}] = Repo.all(Oban.Job)
    assert blocker_args == job_args(blocker)

    blocker
    |> Invocation.transition_changeset(%{
      status: :complete,
      stage: :complete,
      completed_at: @now
    })
    |> Repo.update!()

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(deferred).stage == :received

    assert Enum.any?(Repo.all(Oban.Job), fn job ->
             job.worker == "ContextBot.Workers.EligibilityWorker" and
               job.args == job_args(deferred)
           end)
  end

  test "a backlog larger than max pending drains only into currently free active slots" do
    backlog =
      for index <- 1..5 do
        invocation("capacity-backlog-#{index}", :deferred_capacity, minutes_ago: 10 - index)
      end

    configure(batch_size: 10, settings: settings(max_pending: 2))

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Enum.map(backlog, &Repo.reload!(&1).stage) == [
             :received,
             :received,
             :deferred_capacity,
             :deferred_capacity,
             :deferred_capacity
           ]

    assert length(Repo.all(Oban.Job)) == 2
  end

  test "budget work waits for the UTC rollover and all prior admission windows" do
    budget = accepted_budget_invocation("budget-rollover", minutes_ago: 3)

    historical =
      invocation("recent-admission", :complete,
        actor_did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
        minutes_ago: 2,
        admitted_at: DateTime.add(@now, -5, :minute),
        completed_at: @now
      )

    restrictive =
      settings(
        global_hourly_limit: 1,
        global_daily_limit: 50,
        actor_hourly_limit: 2,
        actor_daily_limit: 5
      )

    configure(now: DateTime.add(@rollover, -1, :second), settings: restrictive)
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(budget).stage == :deferred_budget

    configure(now: @now, settings: restrictive)
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(budget).stage == :deferred_budget
    assert [] = Repo.all(Oban.Job)

    historical
    |> Ecto.Changeset.change(
      admitted_at: @now |> DateTime.add(-2, :hour) |> DateTime.truncate(:microsecond)
    )
    |> Repo.update!()

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(budget).stage == :thread_ready
    assert [%Oban.Job{worker: "ContextBot.Workers.ResearchWorker"}] = Repo.all(Oban.Job)
  end

  test "budget work without same-workflow eligibility evidence stays deferred" do
    incomplete =
      accepted_budget_invocation("missing-evidence", minutes_ago: 2)
      |> Ecto.Changeset.change(eligibility_evidence: nil)
      |> Repo.update!()

    configure()

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(incomplete).stage == :deferred_budget
    assert [] = Repo.all(Oban.Job)
  end

  test "budget selection uses each actual next-attempt cost cumulatively" do
    cheap =
      accepted_budget_invocation("cheap-repair",
        minutes_ago: 4,
        deferred_attempt_kind: :repair
      )

    expensive =
      accepted_budget_invocation("expensive-research",
        minutes_ago: 3,
        deferred_attempt_kind: :research
      )

    constrained =
      settings(
        anthropic_daily_budget_usd: "9.000000",
        anthropic_research_reservation_usd: "5.500000",
        anthropic_continuation_reservation_usd: "5.500000",
        anthropic_repair_reservation_usd: "4.100000",
        anthropic_retry_reservation_usd: "5.500000"
      )

    configure(batch_size: 10, settings: constrained)
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Repo.reload!(cheap).stage == :thread_ready
    assert Repo.reload!(expensive).stage == :deferred_budget

    assert Enum.count(Repo.all(Oban.Job), &(&1.worker == "ContextBot.Workers.ResearchWorker")) ==
             1
  end

  test "maintenance emits only allowlisted attempt metadata for claimed work" do
    invocation = invocation("logged-maintenance", :deferred_capacity, minutes_ago: 2)
    configure()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn ->
          assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}, attempt: 3})
        end
      )

    assert log =~ "context_bot_attempt"
    assert log =~ "\"invocation_id\":#{invocation.id}"
    assert log =~ "\"attempt_kind\":\"maintenance\""
    assert log =~ "\"attempt_index\":3"
    refute log =~ invocation.invocation_uri
    refute log =~ invocation.actor_did
    refute log =~ "notification-body"
  end

  test "recovery enqueues exactly the idempotent worker for every resumable stage" do
    expected = [
      {invocation("recover-received", :received, minutes_ago: 9),
       "ContextBot.Workers.EligibilityWorker"},
      {invocation("recover-checking", :checking_eligibility, minutes_ago: 8),
       "ContextBot.Workers.EligibilityWorker"},
      {invocation("recover-thread", :capturing_thread, minutes_ago: 8),
       "ContextBot.Workers.ThreadWorker"},
      {invocation("recover-thread-ready", :thread_ready, minutes_ago: 7),
       "ContextBot.Workers.ResearchWorker"},
      {invocation("recover-research", :researching, minutes_ago: 6),
       "ContextBot.Workers.ResearchWorker"},
      {invocation("recover-reply", :reply_ready, minutes_ago: 5),
       "ContextBot.Workers.ReplyWorker"},
      {invocation("recover-publishing", :publishing, minutes_ago: 4),
       "ContextBot.Workers.ReplyWorker"}
    ]

    for stage <- [:ineligible, :failed, :complete] do
      invocation("terminal-#{stage}", stage, minutes_ago: 20, completed_at: @now)
    end

    configure(batch_size: 20)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    jobs = Repo.all(from job in Oban.Job, order_by: [asc: job.id])
    assert length(jobs) == 7

    assert Enum.map(jobs, &{&1.worker, &1.args}) ==
             Enum.map(expected, fn {invocation, worker} -> {worker, job_args(invocation)} end)
  end

  test "bounded recovery lets active work consume one pass but not permanently starve later work" do
    active = invocation("already-active", :received, minutes_ago: 5)
    missing = invocation("actually-missing", :capturing_thread, minutes_ago: 4)

    Oban.Job.new(job_args(active),
      worker: "ContextBot.Workers.EligibilityWorker",
      queue: :eligibility
    )
    |> Repo.insert!()

    configure(batch_size: 1)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Repo.all(from job in Oban.Job, order_by: [asc: job.id])
           |> Enum.map(&{&1.worker, &1.args}) == [
             {"ContextBot.Workers.EligibilityWorker", job_args(active)}
           ]

    active
    |> Invocation.transition_changeset(%{status: :complete, stage: :complete, completed_at: @now})
    |> Repo.update!()

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Enum.map(
             Repo.all(from job in Oban.Job, order_by: [asc: job.id]),
             &{&1.worker, &1.args}
           ) == [
             {"ContextBot.Workers.EligibilityWorker", job_args(active)},
             {"ContextBot.Workers.ThreadWorker", job_args(missing)}
           ]
  end

  test "permanent no-op recovery prefixes rotate while due deferred work gets a bounded slot" do
    oldest_active = invocation("fair-active-oldest", :received, minutes_ago: 10)

    fresh_lease =
      invocation("fair-fresh-lease", :researching,
        minutes_ago: 9,
        research_claim_token: "research-still-running",
        research_claimed_at: DateTime.add(@now, -1, :second)
      )

    later_active = invocation("fair-active-later", :received, minutes_ago: 8)
    missing = invocation("fair-missing", :capturing_thread, minutes_ago: 7)
    due_deferred = invocation("fair-deferred", :deferred_capacity, minutes_ago: 6)

    for invocation <- [oldest_active, later_active] do
      invocation
      |> job_args()
      |> Oban.Job.new(worker: "ContextBot.Workers.EligibilityWorker", queue: :eligibility)
      |> Repo.insert!()
    end

    terminal_job(fresh_lease, "ContextBot.Workers.ResearchWorker", "completed")

    configure(batch_size: 2, research_claim_lease_ms: 60_000)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(due_deferred).stage == :received

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Enum.any?(Repo.all(Oban.Job), fn job ->
             job.worker == "ContextBot.Workers.ThreadWorker" and job.args == job_args(missing)
           end)

    assert Repo.reload!(oldest_active).stage == :received
    assert Repo.reload!(fresh_lease).stage == :researching
    assert Repo.reload!(later_active).stage == :received
  end

  test "terminal Oban histories are preserved while safe work receives a replacement" do
    discarded = invocation("discarded", :received, minutes_ago: 5)
    cancelled = invocation("cancelled", :checking_eligibility, minutes_ago: 4)
    missing = invocation("after-terminal-history", :capturing_thread, minutes_ago: 3)

    terminal_job(discarded, "ContextBot.Workers.EligibilityWorker", "discarded")
    terminal_job(cancelled, "ContextBot.Workers.EligibilityWorker", "cancelled")
    configure(batch_size: 2)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Repo.reload!(discarded).stage == :received
    assert Repo.reload!(cancelled).stage == :checking_eligibility
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(discarded))) == 2
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(cancelled))) == 2
    refute Enum.any?(Repo.all(Oban.Job), &(&1.args == job_args(missing)))

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Enum.any?(Repo.all(Oban.Job), &(&1.args == job_args(missing)))

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(discarded))) == 2
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(cancelled))) == 2
  end

  test "recovery repairs a deferred claim whose enqueue failed after an older job completed" do
    deferred = invocation("claim-enqueue-gap", :deferred_capacity, minutes_ago: 5)

    terminal_job(
      deferred,
      "ContextBot.Workers.EligibilityWorker",
      "completed",
      DateTime.add(@now, -30, :second)
    )

    Repo.query!("""
    CREATE TEMP TRIGGER reject_eligibility_enqueue
    BEFORE INSERT ON oban_jobs
    WHEN NEW.worker = 'ContextBot.Workers.EligibilityWorker'
    BEGIN
      SELECT RAISE(ABORT, 'injected eligibility enqueue failure');
    END
    """)

    configure()

    assert_raise Exqlite.Error, ~r/injected eligibility enqueue failure/, fn ->
      DeferredWorker.perform(%Oban.Job{args: %{}})
    end

    assert Repo.reload!(deferred).stage == :received
    Repo.query!("DROP TRIGGER reject_eligibility_enqueue")

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Repo.reload!(deferred).stage == :received

    assert Enum.count(Repo.all(Oban.Job), fn job ->
             job.worker == "ContextBot.Workers.EligibilityWorker" and
               job.args == job_args(deferred)
           end) == 2
  end

  test "a completed same-generation job without a handoff receives one replacement" do
    invocation = invocation("same-generation-no-handoff", :received, minutes_ago: 5)
    transitioned_at = DateTime.add(@now, -10, :second)

    Repo.update_all(
      from(candidate in Invocation, where: candidate.id == ^invocation.id),
      set: [updated_at: transitioned_at]
    )

    terminal_job(
      invocation,
      "ContextBot.Workers.EligibilityWorker",
      "completed",
      DateTime.add(@now, -5, :second)
    )

    configure()
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :received
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(invocation))) == 2
  end

  test "fresh research and publication leases suppress completed no-op recovery until expiry" do
    fresh_research =
      invocation("fresh-research", :researching,
        minutes_ago: 5,
        research_claim_token: "research-old-job",
        research_claimed_at: DateTime.add(@now, -1, :second)
      )

    fresh_publication =
      invocation("fresh-publication", :publishing,
        minutes_ago: 4,
        publication_claim_token: "publication-old-job",
        publication_claimed_at: DateTime.add(@now, -1, :second)
      )

    terminal_job(fresh_research, "ContextBot.Workers.ResearchWorker", "completed")
    terminal_job(fresh_publication, "ContextBot.Workers.ReplyWorker", "completed")
    configure(batch_size: 10, research_claim_lease_ms: 60_000, publication_claim_lease_ms: 60_000)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(fresh_research))) == 1
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(fresh_publication))) == 1

    configure(
      now: DateTime.add(@now, 21_600_001, :millisecond),
      batch_size: 10,
      research_claim_lease_ms: 60_000,
      publication_claim_lease_ms: 60_000
    )

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(fresh_research))) == 2
    assert Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(fresh_publication))) == 2
  end

  test "a maintenance pass inspects no more invocation candidates than its configured batch" do
    invocations =
      for index <- 1..5 do
        invocation("bounded-terminal-#{index}", :received, minutes_ago: 10 - index)
      end

    Enum.each(invocations, fn invocation ->
      terminal_job(invocation, "ContextBot.Workers.EligibilityWorker", "discarded")
    end)

    configure(batch_size: 2)
    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Enum.all?(invocations, &(Repo.reload!(&1).stage == :received))

    assert Enum.map(invocations, fn invocation ->
             Enum.count(Repo.all(Oban.Job), &(&1.args == job_args(invocation)))
           end) == [2, 2, 1, 1, 1]
  end

  test "workflow recovery query has a matching partial fairness index" do
    %{rows: rows} = Repo.query!("PRAGMA index_list('invocations')")
    assert Enum.any?(rows, fn row -> Enum.at(row, 1) == "invocations_recovery_scan_index" end)

    %{rows: index_rows} = Repo.query!("PRAGMA index_info('invocations_recovery_scan_index')")

    assert Enum.map(index_rows, &Enum.at(&1, 2)) == [
             "recovery_checked_at",
             "received_at",
             "id"
           ]

    %{rows: [[index_sql]]} =
      Repo.query!(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
        ["invocations_recovery_scan_index"]
      )

    assert index_sql =~ "WHERE stage IN"
    assert index_sql =~ "'checking_eligibility'"
    assert index_sql =~ "'publishing'"

    {query_sql, query_params} = SQL.to_sql(:all, Repo, DeferredWorker.recovery_query(2))

    %{rows: plan_rows} = Repo.query!("EXPLAIN QUERY PLAN " <> query_sql, query_params)
    plan = Enum.map_join(plan_rows, "\n", &List.last/1)

    assert plan =~ "USING INDEX invocations_recovery_scan_index"
    refute plan =~ "USE TEMP B-TREE FOR ORDER BY"
  end

  defp configure(overrides \\ []) do
    config =
      [now: @now, settings: settings(), batch_size: 25]
      |> Keyword.merge(overrides)

    Application.put_env(:context_bot, DeferredWorker, config)
  end

  defp settings(overrides \\ []) do
    overrides
    |> Keyword.put_new(:anthropic_daily_budget_usd, "20.000000")
    |> Settings.load()
  end

  defp accepted_budget_invocation(rkey, options) do
    invocation(
      rkey,
      :deferred_budget,
      Keyword.merge(
        [
          defer_until: @rollover,
          admitted_at: DateTime.add(@rollover, -2, :hour),
          eligibility_method: "bluesky_elder",
          eligibility_evidence: %{"label" => "bluesky-elder"},
          canonical_thread: "ancestor context",
          canonical_thread_version: "1",
          root_uri: "at://did:plc:root/app.bsky.feed.post/root",
          root_cid: "bafyroot"
        ],
        options
      )
    )
  end

  defp invocation(rkey, stage, options) do
    actor_did = Keyword.get(options, :actor_did, @actor_did)
    minutes_ago = Keyword.fetch!(options, :minutes_ago)
    uri = "at://#{actor_did}/app.bsky.feed.post/#{rkey}"
    cid = "bafy#{rkey}"

    base = %{
      invocation_uri: uri,
      notification_cid: cid,
      current_cid: cid,
      actor_did: actor_did,
      actor_handle: "private-handle.example",
      raw_notification: %{"secret" => "notification-body", "uri" => uri},
      received_at: DateTime.add(@now, -minutes_ago, :minute),
      status: stage,
      stage: stage
    }

    extra = options |> Keyword.drop([:actor_did, :minutes_ago]) |> Map.new()

    %Invocation{}
    |> Invocation.changeset(Map.merge(base, extra))
    |> Repo.insert!()
  end

  defp job_args(invocation) do
    %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
  end

  defp terminal_job(invocation, worker, state, completed_at \\ @now) do
    job =
      invocation
      |> job_args()
      |> Oban.Job.new(worker: worker, queue: :maintenance)
      |> Repo.insert!()

    changes =
      case state do
        "completed" -> [state: state, completed_at: completed_at]
        "cancelled" -> [state: state, cancelled_at: @now]
        "discarded" -> [state: state, discarded_at: @now]
      end

    job
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp executing_job(invocation, worker, queue) do
    job =
      invocation
      |> job_args()
      |> Oban.Job.new(worker: worker, queue: queue)
      |> Repo.insert!()

    job
    |> Ecto.Changeset.change(
      state: "executing",
      attempted_at: DateTime.add(@now, -21_600_001, :millisecond),
      attempted_by: ["abandoned-node"]
    )
    |> Repo.update!()
  end
end
