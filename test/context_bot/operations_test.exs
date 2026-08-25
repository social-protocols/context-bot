defmodule ContextBot.OperationsTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.Operations
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-31 12:00:00Z]

  test "health exposes bounded operational aggregates without persisted or session identity data" do
    pending = invocation(:researching, DateTime.add(@now, -90, :second))
    _deferred = invocation(:deferred_budget, DateTime.add(@now, -60, :second))

    _failed =
      invocation(:failed, DateTime.add(@now, -30, :second), %{
        failure_category: :provider_auth,
        failure_detail: %{"authorization" => "Bearer workflow-secret"},
        completed_at: @now
      })

    insert_budget(pending, :reserved, 500, nil)
    insert_budget(pending, :settled, 700, 123)

    Oban.Job.new(
      %{"uri" => pending.invocation_uri, "token" => "job-secret"},
      worker: "ContextBot.Workers.ResearchWorker",
      queue: :research
    )
    |> Repo.insert!()

    settings =
      Settings.load(
        bot_enabled: true,
        bot_did: "did:plc:botbotbotbotbotbotbotbot",
        bot_handle: "contextbot.example",
        bot_pds_url: "https://pds.private.example",
        anthropic_daily_budget_usd: "10.000000"
      )

    health =
      Operations.health(
        now: @now,
        settings: settings,
        session_status: fn ->
          {:ok, %{authenticated?: true, did: "did:plc:sessionsecretsecretsecret"}}
        end
      )

    assert health == %{
             status: "ok",
             bot: %{enabled: true, session: "authenticated"},
             queues: %{"research" => 1},
             deferred: %{"budget" => 1, "capacity" => 0, "rate" => 0},
             failures: %{"provider_auth" => 1},
             budget: %{
               reserved_microdollars: 500,
               settled_microdollars: 123
             },
             oldest_pending_age_seconds: 90
           }

    encoded = Jason.encode!(health)

    for forbidden <- [
          "notification-secret",
          "thread-secret",
          "provider-secret",
          "private-handle.example",
          "did:plc:",
          "at://",
          "Bearer",
          "job-secret",
          "pds.private.example",
          "contextbot.example"
        ] do
      refute encoded =~ forbidden
    end
  end

  test "health treats provider session failure as degradation and disabled mode avoids the call" do
    degraded =
      Operations.health(
        now: @now,
        settings:
          Settings.load(
            bot_enabled: true,
            bot_did: "did:plc:botbotbotbotbotbotbotbot",
            bot_handle: "contextbot.example",
            bot_pds_url: "https://pds.private.example",
            anthropic_daily_budget_usd: "10.000000"
          ),
        session_status: fn -> raise "provider token must not escape" end
      )

    assert degraded.status == "ok"
    assert degraded.bot.session == "unavailable"
    refute Jason.encode!(degraded) =~ "provider token"

    disabled =
      Operations.health(
        now: @now,
        settings: Settings.load(bot_enabled: false),
        session_status: fn -> flunk("disabled health must not inspect a session") end
      )

    assert disabled.bot == %{enabled: false, session: "disabled"}
  end

  test "health bounds a blocked session lookup and degrades without losing liveness" do
    started_at = System.monotonic_time(:millisecond)

    health =
      Operations.health(
        now: @now,
        settings:
          Settings.load(
            bot_enabled: true,
            bot_did: "did:plc:botbotbotbotbotbotbotbot",
            bot_handle: "contextbot.example",
            bot_pds_url: "https://pds.private.example",
            anthropic_daily_budget_usd: "10.000000"
          ),
        session_timeout_ms: 10,
        session_status: fn ->
          Process.sleep(100)
          {:ok, %{authenticated?: true}}
        end
      )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    assert health.status == "ok"
    assert health.bot.session == "unavailable"
    assert duration_ms < 80
  end

  test "structured attempt logs contain only the finite allowlisted fields" do
    invocation = invocation(:researching, @now)
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn ->
          assert :ok =
                   Operations.log_attempt(invocation,
                     attempt_kind: :research,
                     attempt_index: 2,
                     status_code: 429,
                     duration_ms: 37,
                     failure_category: :rate_limited,
                     media_disposition: :supported,
                     image_count: 4,
                     request: %{authorization: "Bearer request-secret"},
                     client: %{token: "client-secret"},
                     session: %{did: "did:plc:session-secret"},
                     headers: %{"x-api-key" => "header-secret"}
                   )
        end
      )

    decoded = Jason.decode!(log)

    assert decoded["message"] == "context_bot_attempt"
    assert decoded["invocation_id"] == invocation.id
    assert decoded["stage"] == "researching"
    assert decoded["attempt_kind"] == "research"
    assert decoded["attempt_index"] == 2
    assert decoded["status_code"] == 429
    assert decoded["duration_ms"] == 37
    assert decoded["failure_category"] == "rate_limited"
    assert decoded["media_disposition"] == "supported"
    assert decoded["image_count"] == 4

    for forbidden <- [
          "notification-secret",
          "thread-secret",
          "provider-secret",
          "private-handle.example",
          "at://",
          "did:plc:",
          "Bearer",
          "request-secret",
          "client-secret",
          "header-secret"
        ] do
      refute log =~ forbidden
    end
  end

  test "repository queries are not logged" do
    invocation = invocation(:researching, @now)
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :debug, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn ->
          assert Repo.get_by(Invocation, actor_handle: invocation.actor_handle).id ==
                   invocation.id
        end
      )

    assert log == ""
  end

  defp invocation(stage, received_at, extra \\ %{}) do
    suffix = "#{stage}-#{System.unique_integer([:positive])}"
    uri = "at://did:plc:privateactor/app.bsky.feed.post/#{suffix}"
    cid = "bafy#{suffix}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: cid,
          actor_did: "did:plc:privateactor",
          actor_handle: "private-handle.example",
          raw_notification: %{"body" => "notification-secret", "uri" => uri},
          raw_thread: %{"body" => "thread-secret"},
          anthropic_messages: %{"body" => "provider-secret"},
          received_at: received_at,
          status: stage,
          stage: stage
        },
        extra
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_budget(invocation, state, reserved, settled) do
    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      attempt_key: "health-#{state}-#{System.unique_integer([:positive])}",
      invocation_id: invocation.id,
      budget_date: DateTime.to_date(@now),
      kind: :research,
      reserved_microdollars: reserved,
      settled_microdollars: settled,
      state: state
    })
    |> Repo.insert!()
  end
end
