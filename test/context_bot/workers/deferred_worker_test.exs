defmodule ContextBot.Workers.DeferredWorkerTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Settings
  alias ContextBot.Workers.DeferredWorker
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-31 00:00:01.000000Z]
  @rollover ~U[2026-07-31 00:00:00.000000Z]
  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    previous = Application.get_env(:context_bot, DeferredWorker)

    on_exit(fn ->
      if previous do
        Application.put_env(:context_bot, DeferredWorker, previous)
      else
        Application.delete_env(:context_bot, DeferredWorker)
      end
    end)

    :ok
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

  test "recovery enqueues exactly the idempotent worker for every resumable stage" do
    expected = [
      {invocation("recover-received", :received, minutes_ago: 9),
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
    assert length(jobs) == 6

    assert Enum.map(jobs, &{&1.worker, &1.args}) ==
             Enum.map(expected, fn {invocation, worker} -> {worker, job_args(invocation)} end)
  end

  test "an older stage with active work does not consume the missing-job recovery batch" do
    active = invocation("already-active", :received, minutes_ago: 5)
    missing = invocation("actually-missing", :capturing_thread, minutes_ago: 4)

    Oban.Job.new(job_args(active),
      worker: "ContextBot.Workers.EligibilityWorker",
      queue: :eligibility
    )
    |> Repo.insert!()

    configure(batch_size: 1)

    assert :ok = DeferredWorker.perform(%Oban.Job{args: %{}})

    assert Enum.map(
             Repo.all(from job in Oban.Job, order_by: [asc: job.id]),
             &{&1.worker, &1.args}
           ) == [
             {"ContextBot.Workers.EligibilityWorker", job_args(active)},
             {"ContextBot.Workers.ThreadWorker", job_args(missing)}
           ]
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
end
