defmodule ContextBot.Workers.EligibilityWorkerTest.GateStub do
  @moduledoc false

  def check(actor_did, observed_handle, now, settings, client) do
    send(self(), {:eligibility_check, actor_did, observed_handle, now, settings, client})

    case Process.get({__MODULE__, :result}) do
      nil -> raise "eligibility result was not configured"
      result -> result
    end
  end
end

defmodule ContextBot.Workers.EligibilityWorkerTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.{LimitNotice, LimitNoticeRecorder, Settings}
  alias ContextBot.Reply.Intent
  alias ContextBot.Workers.EligibilityWorker
  alias ContextBot.Workers.EligibilityWorkerTest.GateStub
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-30 12:00:00Z]
  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    previous_config = Application.get_env(:context_bot, EligibilityWorker)

    on_exit(fn ->
      Process.delete({GateStub, :result})

      if previous_config do
        Application.put_env(:context_bot, EligibilityWorker, previous_config)
      else
        Application.delete_env(:context_bot, EligibilityWorker)
      end
    end)

    :ok
  end

  test "claims received work, records allowlist evidence, and admits one thread job" do
    invocation = invocation("received-eligible", :received)
    configure(settings(operator_allowed_dids: [@actor_did]))

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :capturing_thread
    assert persisted.stage == :capturing_thread
    assert persisted.eligibility_method == "operator_allowlist"

    assert persisted.eligibility_evidence == %{
             "actor_did" => @actor_did,
             "source" => "operator_allowlist"
           }

    assert DateTime.compare(persisted.admitted_at, @now) == :eq

    assert [%Oban.Job{worker: "ContextBot.Workers.ThreadWorker", queue: "thread"}] =
             Repo.all(Oban.Job)
  end

  test "logs an eligibility attempt using only allowlisted metadata" do
    invocation = invocation("logged-eligibility", :received)
    configure(settings(operator_allowed_dids: [@actor_did]))
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    assert log =~ "\"invocation_id\":#{invocation.id}"
    assert log =~ "\"stage\":\"checking_eligibility\""
    assert log =~ "\"attempt_kind\":\"eligibility\""
    refute log =~ invocation.invocation_uri
    refute log =~ @actor_did
  end

  test "resumes its own checking_eligibility checkpoint" do
    invocation = invocation("resume-checking", :checking_eligibility)
    configure(settings(operator_allowed_dids: [@actor_did]))

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).status == :capturing_thread
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "reconsiders deferred_rate with current eligibility rather than prior evidence" do
    invocation =
      invocation("reconsider-rate", :deferred_rate, %{
        eligibility_method: "operator_allowlist",
        eligibility_evidence: %{"stale" => true},
        defer_until: DateTime.add(@now, -1, :second)
      })

    Process.put(
      {GateStub, :result},
      {:eligible, :public, %{"actor_did" => @actor_did, "source" => "public"}}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    assert_received {:eligibility_check, @actor_did, "actor.example", @now, _settings, _client}
    persisted = Repo.reload!(invocation)
    assert persisted.status == :capturing_thread
    assert persisted.eligibility_method == "public"
    assert persisted.eligibility_evidence == %{"actor_did" => @actor_did, "source" => "public"}
    assert persisted.defer_until == nil
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "marks an authoritative negative terminal without downstream work" do
    invocation = invocation("ineligible", :received)
    Process.put({GateStub, :result}, :ineligible)
    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :ineligible
    assert persisted.stage == :ineligible
    assert DateTime.compare(persisted.completed_at, @now) == :eq
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "returns retryable lookup errors while retaining a resumable checkpoint" do
    invocation = invocation("identity-outage", :received)
    Process.put({GateStub, :result}, {:error, :identity_unavailable})
    configure(settings(), eligibility: GateStub)

    assert {:error, :identity_unavailable} = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :checking_eligibility
    assert persisted.stage == :checking_eligibility

    assert persisted.eligibility_evidence == %{
             "reason" => "identity_unavailable",
             "result" => "lookup_unavailable"
           }

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "stores only bounded allowlisted evidence fields" do
    invocation = invocation("safe-evidence", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :bluesky_elder,
       %{
         "actor_did" => @actor_did,
         "label" => "bluesky-elder",
         "labeler_did" => "did:plc:e4elbtctnfqocyfcml6h2lf7",
         "raw_profile" => %{"description" => String.duplicate("x", 10_000)},
         "token" => "Bearer should-never-persist"
       }}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)

    assert persisted.eligibility_evidence == %{
             "actor_did" => @actor_did,
             "label" => "bluesky-elder",
             "labeler_did" => "did:plc:e4elbtctnfqocyfcml6h2lf7"
           }

    assert byte_size(Jason.encode!(persisted.eligibility_evidence)) < 512
  end

  test "safely persists and admits finite string-key team evidence" do
    invocation = invocation("safe-team-evidence", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :bsky_team,
       %{
         "actor_did" => @actor_did,
         "handle" => "alice.bsky.team",
         "verification" => "bidirectional",
         "raw_document" => %{"alsoKnownAs" => String.duplicate("x", 10_000)},
         "token" => "Bearer should-never-persist"
       }}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :capturing_thread
    assert persisted.eligibility_method == "bsky_team"

    assert persisted.eligibility_evidence == %{
             "actor_did" => @actor_did,
             "handle" => "alice.bsky.team",
             "verification" => "bidirectional"
           }

    assert byte_size(Jason.encode!(persisted.eligibility_evidence)) < 512

    assert [%Oban.Job{worker: "ContextBot.Workers.ThreadWorker", queue: "thread"}] =
             Repo.all(Oban.Job)
  end

  test "stores only bounded public evidence fields" do
    invocation = invocation("safe-public-evidence", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :public,
       %{
         "actor_did" => @actor_did,
         "source" => "public",
         "raw_profile" => %{"description" => String.duplicate("x", 10_000)},
         "token" => "Bearer should-never-persist"
       }}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :capturing_thread
    assert persisted.eligibility_method == "public"

    assert persisted.eligibility_evidence == %{
             "actor_did" => @actor_did,
             "source" => "public"
           }
  end

  test "defers a public actor at the public daily limit without enqueueing thread work" do
    historical("public-rate-one", DateTime.add(@now, -2, :hour))
    invocation = invocation("worker-public-rate", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :public, %{"actor_did" => @actor_did, "source" => "public"}}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :deferred_rate
    assert persisted.eligibility_method == "public"
    assert DateTime.after?(persisted.defer_until, @now)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "stores eligible rate deferral without enqueueing thread work" do
    historical("rate-one", DateTime.add(@now, -30, :minute))
    historical("rate-two", DateTime.add(@now, -10, :minute))
    invocation = invocation("worker-rate", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :bluesky_elder,
       %{
         "actor_did" => @actor_did,
         "label" => "bluesky-elder",
         "labeler_did" => "did:plc:e4elbtctnfqocyfcml6h2lf7"
       }}
    )

    configure(settings(), eligibility: GateStub)

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :deferred_rate
    assert persisted.eligibility_method == "bluesky_elder"
    assert DateTime.after?(persisted.defer_until, @now)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "posts exactly one actor-rate notice and does not admit research" do
    historical("rate-one", DateTime.add(@now, -30, :minute))
    historical("rate-two", DateTime.add(@now, -10, :minute))
    invocation = invocation("worker-rate-notice", :received)
    rkey = "3mzzzznoticeel"

    Process.put(
      {GateStub, :result},
      {:eligible, :bluesky_elder,
       %{
         "actor_did" => @actor_did,
         "label" => "bluesky-elder",
         "labeler_did" => "did:plc:e4elbtctnfqocyfcml6h2lf7"
       }}
    )

    configure(
      settings(bot_did: "did:plc:contextbot123"),
      eligibility: GateStub,
      limit_notice: LimitNotice,
      intent_builder: &Intent.build/5,
      tid_generator: fn _timestamp -> rkey end
    )

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.status == :reply_ready
    assert persisted.admitted_at == nil
    assert persisted.limit_notice_kind == :actor_rate
    assert persisted.selected_reply == LimitNotice.actor_rate_text(persisted.defer_until)
    refute persisted.selected_reply =~ "@"

    assert [%Oban.Job{worker: "ContextBot.Workers.ReplyWorker", queue: "reply"}] =
             Repo.all(Oban.Job)
  end

  test "does not use the actor-limit notice for a global rate deferral" do
    for index <- 1..10 do
      invocation(
        "global-hour-#{index}",
        :complete,
        %{admitted_at: DateTime.add(@now, -3_600 + index, :second), completed_at: @now},
        "did:plc:globalhour#{index}"
      )
    end

    invocation = invocation("worker-global-rate", :received)

    Process.put(
      {GateStub, :result},
      {:eligible, :bluesky_elder,
       %{
         "actor_did" => @actor_did,
         "label" => "bluesky-elder",
         "labeler_did" => "did:plc:e4elbtctnfqocyfcml6h2lf7"
       }}
    )

    configure(settings(), eligibility: GateStub, limit_notice: LimitNoticeRecorder)

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).status == :deferred_rate
    refute_received {:limit_notice, :actor_rate, _}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "does not use the actor-limit notice for a capacity deferral" do
    pending = invocation("capacity-other-notice", :received, %{}, "did:plc:otherpending")
    invocation = invocation("worker-capacity-notice", :received)

    configure(
      settings(operator_allowed_dids: [@actor_did], max_pending: 1),
      limit_notice: LimitNoticeRecorder
    )

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).status == :deferred_capacity
    assert Repo.reload!(pending).status == :received
    refute_received {:limit_notice, :actor_rate, _}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "stores eligible capacity deferral without enqueueing thread work" do
    pending = invocation("capacity-other", :received, %{}, "did:plc:otherpending")
    invocation = invocation("worker-capacity", :received)
    configure(settings(operator_allowed_dids: [@actor_did], max_pending: 1))

    assert :ok = perform(invocation)

    assert Repo.reload!(invocation).status == :deferred_capacity
    assert Repo.reload!(pending).status == :received
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "ignores jobs whose invocation is missing or no longer at a claimable stage" do
    invocation = invocation("already-ineligible", :ineligible, %{completed_at: @now})
    configure(settings(operator_allowed_dids: [@actor_did]))

    assert :ok = perform(invocation)

    assert :ok =
             EligibilityWorker.perform(%Oban.Job{
               args: %{
                 "uri" => "at://did:plc:missing/app.bsky.feed.post/missing",
                 "cid" => "bafymissing"
               }
             })

    assert Repo.reload!(invocation).status == :ineligible
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  defp configure(settings, overrides \\ []) do
    Application.put_env(
      :context_bot,
      EligibilityWorker,
      Keyword.merge(
        [settings: settings, now: @now, limit_notice: ContextBot.LimitNoticeNoop],
        overrides
      )
    )
  end

  defp settings(overrides \\ []), do: Settings.load(overrides)

  defp perform(invocation) do
    EligibilityWorker.perform(%Oban.Job{
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
    })
  end

  defp historical(rkey, admitted_at) do
    invocation(rkey, :complete, %{admitted_at: admitted_at, completed_at: @now})
  end

  defp invocation(rkey, status, extra \\ %{}, actor_did \\ @actor_did) do
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
          received_at: DateTime.add(@now, -1, :minute),
          status: status,
          stage: status
        },
        extra
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end
end
