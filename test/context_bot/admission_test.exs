defmodule ContextBot.AdmissionTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.{Admission, Settings}
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-30 12:00:00Z]
  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"

  test "admits and commits capturing_thread with its exact future ThreadWorker job" do
    invocation = eligible_invocation("success", @actor_did)

    assert {:ok, admitted} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert admitted.status == :capturing_thread
    assert admitted.stage == :capturing_thread
    assert DateTime.compare(admitted.admitted_at, @now) == :eq
    assert admitted.defer_until == nil

    assert [%Oban.Job{} = job] = Repo.all(Oban.Job)
    assert job.worker == "ContextBot.Workers.ThreadWorker"
    assert job.queue == "thread"
    assert job.args == %{"cid" => invocation.notification_cid, "uri" => invocation.invocation_uri}
  end

  test "rejects a ThreadWorker job that does not target the admitted invocation" do
    invocation = eligible_invocation("wrong-job-target", @actor_did)

    wrong_job =
      Oban.Job.new(
        %{"uri" => "at://did:plc:other/app.bsky.feed.post/other", "cid" => "bafyother"},
        worker: "ContextBot.Workers.ThreadWorker",
        queue: :thread
      )

    assert_raise ArgumentError, ~r/requires a valid ThreadWorker job/, fn ->
      Admission.admit(invocation, @now, settings(), wrong_job)
    end

    assert Repo.reload!(invocation).status == :checking_eligibility
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "enforces the actor rolling-hour limit and defers to its earliest expiry" do
    historical("actor-hour-oldest", @actor_did, DateTime.add(@now, -3_599, :second))
    historical("actor-hour-newest", @actor_did, DateTime.add(@now, -1_800, :second))
    invocation = eligible_invocation("actor-hour-current", @actor_did)

    assert {:deferred, :rate, deferred} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert deferred.status == :deferred_rate
    assert deferred.stage == :deferred_rate
    assert DateTime.compare(deferred.defer_until, DateTime.add(@now, 1, :second)) == :eq
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "enforces the actor rolling-24-hour limit" do
    for {hours_ago, index} <- Enum.with_index([2, 3, 4, 5, 23], 1) do
      historical(
        "actor-day-#{index}",
        @actor_did,
        DateTime.add(@now, -hours_ago, :hour)
      )
    end

    invocation = eligible_invocation("actor-day-current", @actor_did)

    assert {:deferred, :rate, deferred} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert DateTime.compare(deferred.defer_until, DateTime.add(@now, 1, :hour)) == :eq
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "enforces the global rolling-hour limit" do
    for index <- 1..10 do
      historical(
        "global-hour-#{index}",
        "did:plc:globalhour#{index}",
        DateTime.add(@now, -3_600 + index, :second)
      )
    end

    invocation = eligible_invocation("global-hour-current", @actor_did)

    assert {:deferred, :rate, deferred} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert DateTime.compare(deferred.defer_until, DateTime.add(@now, 1, :second)) == :eq
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "enforces the global rolling-24-hour limit" do
    for index <- 1..50 do
      historical(
        "global-day-#{index}",
        "did:plc:globalday#{index}",
        DateTime.add(@now, -23, :hour)
      )
    end

    invocation = eligible_invocation("global-day-current", @actor_did)

    assert {:deferred, :rate, deferred} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert DateTime.compare(deferred.defer_until, DateTime.add(@now, 1, :hour)) == :eq
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "excludes exact rolling-window boundary timestamps" do
    historical("actor-hour-boundary", @actor_did, DateTime.add(@now, -1, :hour))
    historical("actor-day-boundary", @actor_did, DateTime.add(@now, -24, :hour))

    for index <- 1..10 do
      historical(
        "global-hour-boundary-#{index}",
        "did:plc:hourboundary#{index}",
        DateTime.add(@now, -1, :hour)
      )
    end

    for index <- 1..50 do
      historical(
        "global-day-boundary-#{index}",
        "did:plc:dayboundary#{index}",
        DateTime.add(@now, -24, :hour)
      )
    end

    invocation = eligible_invocation("boundary-current", @actor_did)

    assert {:ok, admitted} =
             Admission.admit(invocation, @now, settings(), thread_job(invocation))

    assert admitted.status == :capturing_thread
  end

  test "counts nonterminal pending work while excluding the invocation being admitted" do
    current = eligible_invocation("pending-current", @actor_did)

    for index <- 1..24 do
      pending("pending-other-#{index}")
    end

    refute Admission.capacity_available?(settings())

    assert {:ok, admitted} =
             Admission.admit(current, @now, settings(), thread_job(current))

    assert admitted.status == :capturing_thread

    terminal("pending-terminal")
    assert Repo.aggregate(Invocation, :count) == 26
  end

  test "read-only recovery gates exclude the resumed invocation from capacity and rate windows" do
    invocation =
      insert_invocation("recovery-self", @actor_did, :deferred_budget, %{
        admitted_at: DateTime.add(@now, -10, :minute)
      })

    restrictive =
      settings(
        max_pending: 1,
        actor_hourly_limit: 1,
        actor_daily_limit: 1,
        global_hourly_limit: 1,
        global_daily_limit: 1
      )

    refute Admission.capacity_available?(restrictive)
    assert Admission.capacity_available?(restrictive, invocation.id)
    assert Admission.resume_available?(invocation, @now, restrictive)

    historical("recovery-other", @actor_did, DateTime.add(@now, -5, :minute))
    refute Admission.resume_available?(invocation, @now, restrictive)
  end

  test "defers without a thread job when pending capacity is already full" do
    current = eligible_invocation("capacity-current", @actor_did)

    for index <- 1..25 do
      pending("capacity-other-#{index}")
    end

    assert {:deferred, :capacity, deferred} =
             Admission.admit(current, @now, settings(), thread_job(current))

    assert deferred.status == :deferred_capacity
    assert deferred.stage == :deferred_capacity
    assert deferred.defer_until == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "operator allowlisting never bypasses rate limits" do
    historical("allowlist-one", @actor_did, DateTime.add(@now, -30, :minute))
    historical("allowlist-two", @actor_did, DateTime.add(@now, -10, :minute))

    invocation =
      eligible_invocation("allowlist-current", @actor_did, "operator_allowlist")

    allowlisted_settings = settings(operator_allowed_dids: [@actor_did])

    assert {:deferred, :rate, _deferred} =
             Admission.admit(
               invocation,
               @now,
               allowlisted_settings,
               thread_job(invocation)
             )

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "serializes concurrent claims so only the actor limit is admitted" do
    invocations =
      for index <- 1..4 do
        eligible_invocation("concurrent-#{index}", @actor_did)
      end

    results =
      invocations
      |> Enum.map(fn invocation ->
        Task.async(fn ->
          Admission.admit(invocation, @now, settings(), thread_job(invocation))
        end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _invocation}, &1)) == 2
    assert Enum.count(results, &match?({:deferred, :rate, _invocation}, &1)) == 2
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  defp settings(overrides \\ []), do: Settings.load(overrides)

  defp eligible_invocation(rkey, actor_did, method \\ "bluesky_elder") do
    insert_invocation(rkey, actor_did, :checking_eligibility, %{
      eligibility_method: method,
      eligibility_evidence: %{"actor_did" => actor_did}
    })
  end

  defp pending(rkey), do: insert_invocation(rkey, "did:plc:pending#{rkey}", :received)

  defp terminal(rkey) do
    insert_invocation(rkey, "did:plc:terminal#{rkey}", :complete, %{
      completed_at: @now
    })
  end

  defp historical(rkey, actor_did, admitted_at) do
    insert_invocation(rkey, actor_did, :complete, %{
      admitted_at: admitted_at,
      completed_at: @now
    })
  end

  defp insert_invocation(rkey, actor_did, status, extra \\ %{}) do
    uri = "at://#{actor_did}/app.bsky.feed.post/#{rkey}"
    cid = "bafy#{rkey}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: cid,
          actor_did: actor_did,
          actor_handle: "actor.example",
          raw_notification: %{"uri" => uri, "cid" => cid},
          received_at: DateTime.add(@now, -25, :hour),
          status: status,
          stage: status
        },
        extra
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp thread_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: "ContextBot.Workers.ThreadWorker",
      queue: :thread
    )
  end
end
