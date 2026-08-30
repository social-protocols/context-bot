defmodule ContextBot.LimitNoticeTest.Noop do
  @moduledoc false

  def handoff_actor_rate(_invocation, _deps), do: :ok
  def maybe_post_budget(_invocation, _deps), do: :ok
end

defmodule ContextBot.LimitNoticeTest.PutClient do
  @moduledoc false

  def put_record(repo, collection, rkey, record) do
    send(self(), {:limit_notice_put, repo, collection, rkey, record})

    {:ok, 200, %{},
     %{
       "uri" => "at://#{repo}/#{collection}/#{rkey}",
       "cid" => "bafy-notice-#{rkey}"
     }}
  end
end

defmodule ContextBot.LimitNoticeTest.FailClient do
  @moduledoc false

  def put_record(_repo, _collection, _rkey, _record) do
    send(self(), :limit_notice_put_failed)
    {:error, :session_unavailable}
  end
end

defmodule ContextBot.LimitNoticeTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.LimitNotice
  alias ContextBot.LimitNoticeTest.{FailClient, PutClient}
  alias ContextBot.Reply.Intent
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-30 12:00:00.000000Z]
  @actor_did "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
  @bot_did "did:plc:contextbot123"
  @rkey "3mzzzznotice01"
  @homepage "https://context-bot-social-protocols.fly.dev"

  test "actor-rate copy names the tier limit, retry time, and homepage without mentioning the bot" do
    text = LimitNotice.actor_rate_text(~U[2026-07-30 13:00:00.000000Z])

    assert text ==
             "You have reached today's limit for your tier. Try again after 2026-07-30 13:00 UTC. #{@homepage}"

    refute text =~ "@"
    refute text =~ "getcontext"
    assert String.length(text) <= 300
  end

  test "budget copy names the shared daily budget, 00:00 UTC, and the homepage" do
    text = LimitNotice.budget_text()

    assert text ==
             "The shared daily research budget is used up. Try again after 00:00 UTC. #{@homepage}"

    refute text =~ "@"
    refute text =~ "FUNDING_KEYS"
    assert String.length(text) <= 300
  end

  test "handoff_actor_rate freezes one ReplyWorker notice without admitting research" do
    invocation =
      invocation("actor-rate-notice", :deferred_rate, %{
        defer_until: ~U[2026-07-30 13:00:00.000000Z]
      })

    assert :ok = LimitNotice.handoff_actor_rate(invocation, deps())

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :reply_ready
    assert persisted.status == :reply_ready
    assert persisted.admitted_at == nil
    assert persisted.limit_notice_kind == :actor_rate

    assert persisted.selected_reply ==
             LimitNotice.actor_rate_text(~U[2026-07-30 13:00:00.000000Z])

    assert persisted.reply_validation == %{
             "result" => "limit_notice",
             "reason" => "actor_rate",
             "source" => "local"
           }

    assert persisted.full_response == nil
    assert persisted.reply_rkey == @rkey
    assert persisted.reply_record["text"] == persisted.selected_reply

    assert persisted.reply_record["reply"]["parent"] == %{
             "uri" => invocation.invocation_uri,
             "cid" => invocation.current_cid
           }

    assert [%Oban.Job{worker: "ContextBot.Workers.ReplyWorker", queue: "reply"}] =
             Repo.all(Oban.Job)

    refute Repo.exists?(
             from job in Oban.Job, where: job.worker == "ContextBot.Workers.ThreadWorker"
           )

    refute Repo.exists?(
             from job in Oban.Job, where: job.worker == "ContextBot.Workers.ResearchWorker"
           )
  end

  test "a second actor-rate handoff on the same invocation does not enqueue another notice" do
    invocation =
      invocation("actor-rate-once", :deferred_rate, %{
        defer_until: ~U[2026-07-30 13:00:00.000000Z]
      })

    assert :ok = LimitNotice.handoff_actor_rate(invocation, deps())
    first = Repo.reload!(invocation)
    assert :ok = LimitNotice.handoff_actor_rate(first, deps())

    assert Repo.reload!(invocation).reply_rkey == first.reply_rkey
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "skips a new actor-rate notice when the parent is already a bot post" do
    invocation =
      invocation("reply-to-notice", :deferred_rate, %{
        defer_until: ~U[2026-07-30 13:00:00.000000Z],
        raw_notification: %{
          "uri" => "at://#{@actor_did}/app.bsky.feed.post/reply-to-notice",
          "cid" => "bafyreply-to-notice",
          "record" => %{
            "reply" => %{
              "parent" => %{
                "uri" => "at://#{@bot_did}/app.bsky.feed.post/prior-notice",
                "cid" => "bafyprior"
              }
            }
          }
        }
      })

    assert :ok = LimitNotice.handoff_actor_rate(invocation, deps())

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.admitted_at == nil
    assert persisted.reply_record == nil
    assert persisted.limit_notice_kind == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "skips a new actor-rate notice when the actor already received one this window" do
    _prior =
      invocation("prior-notice", :complete, %{
        limit_notice_kind: :actor_rate,
        limit_notice_posted_at: DateTime.add(@now, -10, :minute),
        completed_at: DateTime.add(@now, -10, :minute)
      })

    invocation =
      invocation("second-notice", :deferred_rate, %{
        defer_until: ~U[2026-07-31 12:00:00.000000Z]
      })

    assert :ok = LimitNotice.handoff_actor_rate(invocation, deps())

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.reply_record == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "dry-run actor-rate deferrals never freeze a notice" do
    invocation =
      invocation("dry-rate", :deferred_rate, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/target",
        invocation_text: "what happened?",
        defer_until: ~U[2026-07-30 13:00:00.000000Z]
      })

    assert :ok = LimitNotice.handoff_actor_rate(invocation, deps())
    assert Repo.reload!(invocation).stage == :deferred_rate
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "budget notice posts once, stays deferred_budget, and does not touch reply intent fields" do
    invocation =
      invocation("budget-notice", :deferred_budget, %{
        admitted_at: DateTime.add(@now, -1, :minute),
        defer_until: ~U[2026-07-31 00:00:00.000000Z],
        deferred_attempt_kind: :research
      })

    assert :ok = LimitNotice.maybe_post_budget(invocation, deps(atproto_client: PutClient))

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.admitted_at == invocation.admitted_at
    assert persisted.limit_notice_kind == :budget
    assert persisted.limit_notice_uri == "at://#{@bot_did}/app.bsky.feed.post/#{@rkey}"
    assert persisted.limit_notice_cid == "bafy-notice-#{@rkey}"
    assert persisted.reply_record == nil
    assert persisted.selected_reply == nil
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert_received {:limit_notice_put, @bot_did, "app.bsky.feed.post", @rkey, record}
    assert record["text"] == LimitNotice.budget_text()

    assert :ok =
             LimitNotice.maybe_post_budget(
               Repo.reload!(invocation),
               deps(atproto_client: PutClient)
             )

    refute_received {:limit_notice_put, _, _, _, _}
  end

  test "a failed budget put claims the slot and does not retry" do
    invocation =
      invocation("budget-fail", :deferred_budget, %{
        admitted_at: DateTime.add(@now, -1, :minute),
        defer_until: ~U[2026-07-31 00:00:00.000000Z]
      })

    assert :ok = LimitNotice.maybe_post_budget(invocation, deps(atproto_client: FailClient))
    assert_received :limit_notice_put_failed

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.limit_notice_kind == :budget
    assert persisted.limit_notice_uri == nil

    assert :ok =
             LimitNotice.maybe_post_budget(
               Repo.reload!(invocation),
               deps(atproto_client: PutClient)
             )

    refute_received {:limit_notice_put, _, _, _, _}
  end

  test "actor-rate notices do not increment admitted_at rate counters" do
    historical =
      invocation("already-admitted", :complete, %{admitted_at: DateTime.add(@now, -10, :minute)})

    overflow =
      invocation("overflow", :deferred_rate, %{
        defer_until: ~U[2026-07-30 13:00:00.000000Z]
      })

    assert :ok = LimitNotice.handoff_actor_rate(overflow, deps())
    assert Repo.reload!(overflow).admitted_at == nil
    assert Repo.reload!(historical).admitted_at == historical.admitted_at

    admitted_count =
      Invocation
      |> where([i], i.actor_did == ^@actor_did and not is_nil(i.admitted_at))
      |> Repo.aggregate(:count)

    assert admitted_count == 1
  end

  defp deps(overrides \\ []) do
    defaults = [
      settings: Settings.load(bot_did: @bot_did),
      now: @now,
      intent_builder: &Intent.build/5,
      tid_generator: fn timestamp_us ->
        assert timestamp_us == DateTime.to_unix(@now, :microsecond)
        @rkey
      end,
      atproto_client: PutClient
    ]

    Map.new(Keyword.merge(defaults, overrides))
  end

  defp invocation(rkey, status, extra) do
    uri = "at://#{@actor_did}/app.bsky.feed.post/#{rkey}"
    cid = "bafy#{rkey}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: cid,
          actor_did: @actor_did,
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
