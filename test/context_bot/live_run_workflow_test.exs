defmodule ContextBot.LiveRunWorkflowTest do
  use ContextBot.DataCase, async: false

  import Ecto.Query

  alias ContextBot.ATProto.PublicClient
  alias ContextBot.LiveRun
  alias ContextBot.POCFixture
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.Invocation

  setup {Req.Test, :verify_on_exit!}

  test "an operator-selected mention traverses the existing public workers and publishes once" do
    fixture = POCFixture.start!()
    invocation_uri = POCFixture.notification()["uri"]
    fetches = start_supervised!({Agent, fn -> 0 end}, id: :live_invocation_fetches)

    Req.Test.stub(PublicClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/xrpc/app.bsky.feed.getPostThread"

      assert URI.decode_query(conn.query_string) == %{
               "depth" => "0",
               "parentHeight" => "80",
               "uri" => invocation_uri
             }

      count = Agent.get_and_update(fetches, &{&1, &1 + 1})
      body = live_invocation_thread()

      body =
        if count == 0,
          do: body,
          else: put_in(body, ["thread", "post", "cid"], POCFixture.fixture_cid("edited"))

      Req.Test.json(conn, body)
    end)

    insert_terminal_history!()

    assert {:ok, invocation, :created} =
             LiveRun.prepare(invocation_uri, settings: fixture.settings, client: PublicClient)

    refute invocation.dry_run
    assert invocation.eligibility_method == "operator_live_demo"
    assert invocation.stage == :capturing_thread

    perform_and_delete!(:thread)
    thread_ready = Repo.reload!(invocation)
    assert thread_ready.canonical_thread_version == "2"
    assert length(thread_ready.canonical_media) == 1
    assert thread_ready.canonical_thread =~ "The root claim."
    assert thread_ready.canonical_thread =~ "The immediate parent claim."
    refute thread_ready.canonical_thread =~ "DESCENDANT"

    perform_and_delete!(:research)
    assert Repo.reload!(invocation).stage == :reply_ready

    perform_and_delete!(:reply)

    assert {:ok, complete} = LiveRun.await(invocation, timeout_ms: 0)
    assert complete.stage == :complete
    assert is_binary(complete.reply_uri)
    assert POCFixture.created_reply_count(fixture) == 1
    assert POCFixture.visible_reply(fixture)["uri"] == complete.reply_uri
    assert Repo.aggregate(BudgetEntry, :count) > 0
    assert POCFixture.call_count(fixture, :profile) == 0
    assert POCFixture.call_count(fixture, :notifications) == 0

    anthropic_calls = POCFixture.call_count(fixture, :anthropic_post)
    pds_writes = POCFixture.call_count(fixture, :pds_put)

    assert {:ok, same, :complete} =
             LiveRun.prepare(invocation_uri, settings: fixture.settings, client: PublicClient)

    assert same.id == invocation.id
    assert same.reply_uri == complete.reply_uri
    assert Repo.aggregate(Invocation, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert POCFixture.call_count(fixture, :anthropic_post) == anthropic_calls
    assert POCFixture.call_count(fixture, :pds_put) == pds_writes
    assert POCFixture.created_reply_count(fixture) == 1
  end

  test "a different nonterminal invocation blocks durable work before model or publication calls" do
    fixture = POCFixture.start!()
    invocation_uri = POCFixture.notification()["uri"]

    Req.Test.stub(PublicClient, fn conn -> Req.Test.json(conn, live_invocation_thread()) end)

    active = insert_invocation!("active", :researching)

    assert {:error, :active_invocation, %{id: id, uri: uri}} =
             LiveRun.prepare(invocation_uri, settings: fixture.settings, client: PublicClient)

    assert id == active.id
    assert uri == active.invocation_uri
    assert Repo.aggregate(Invocation, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert POCFixture.call_count(fixture, :anthropic_post) == 0
    assert POCFixture.call_count(fixture, :pds_put) == 0
  end

  test "an operator-selected video proceeds through research and publishes the reply" do
    fixture = POCFixture.start!()
    invocation_uri = POCFixture.notification()["uri"]

    video_thread =
      live_invocation_thread()
      |> put_in(["thread", "post", "embed"], %{
        "$type" => "app.bsky.embed.video#view",
        "cid" => "bafkreivideo",
        "playlist" => "https://video.bsky.app/watch/example/playlist.m3u8"
      })

    POCFixture.set_thread_result(fixture, {:json, 200, video_thread})
    Req.Test.stub(PublicClient, fn conn -> Req.Test.json(conn, video_thread) end)

    assert {:ok, invocation, :created} =
             LiveRun.prepare(invocation_uri, settings: fixture.settings, client: PublicClient)

    perform_and_delete!(:thread)

    # Video threads now go through research
    thread_ready = Repo.reload!(invocation)
    assert thread_ready.stage == :thread_ready
    assert thread_ready.contains_video == true

    assert [%Oban.Job{queue: "research", worker: "ContextBot.Workers.ResearchWorker"}] =
             Repo.all(Oban.Job)

    # Stub research response
    POCFixture.set_research_response(fixture, %{
      "stop_reason" => "end_turn",
      "content" => [
        %{
          "type" => "text",
          "text" =>
            ContextBot.Research.StructuredFixtures.structured_json(
              "Public reports indicate this is a test.",
              title: "Public Reports",
              full: "Public reports indicate this is a test."
            )
        }
      ]
    })

    perform_and_delete!(:research)

    reply_ready = Repo.reload!(invocation)
    assert reply_ready.stage == :reply_ready
    assert reply_ready.selected_reply =~ "test"
    assert POCFixture.call_count(fixture, :anthropic_post) == 1

    assert [%Oban.Job{queue: "reply", worker: "ContextBot.Workers.ReplyWorker"}] =
             Repo.all(Oban.Job)

    perform_and_delete!(:reply)

    assert {:ok, complete} = LiveRun.await(invocation, timeout_ms: 0)
    assert complete.stage == :complete
    assert POCFixture.created_reply_count(fixture) == 1
  end

  defp perform_and_delete!(queue) do
    job =
      Oban.Job
      |> where([job], job.queue == ^to_string(queue))
      |> Repo.one!()

    attempted = %{job | attempt: max(job.attempt, 1), attempted_at: DateTime.utc_now()}

    assert :ok =
             Oban.Testing.perform_job(attempted,
               repo: Repo,
               engine: Oban.Engines.Lite,
               testing: :manual
             )

    Repo.delete!(Repo.get!(Oban.Job, job.id))
  end

  defp insert_terminal_history!, do: insert_invocation!("terminal-history", :failed)

  defp live_invocation_thread do
    put_in(
      POCFixture.thread_fixture(),
      ["thread", "post", "record"],
      POCFixture.notification()["record"]
    )
  end

  defp insert_invocation!(suffix, stage) do
    uri = "at://did:plc:history/app.bsky.feed.post/#{suffix}"

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: false,
      invocation_uri: uri,
      notification_cid: POCFixture.fixture_cid(suffix),
      current_cid: POCFixture.fixture_cid(suffix),
      actor_did: "did:plc:history",
      raw_notification: %{"source" => "test_history"},
      received_at: DateTime.utc_now(),
      status: stage,
      stage: stage,
      failure_category: if(stage == :failed, do: :provider_response),
      completed_at: if(stage == :failed, do: DateTime.utc_now())
    })
    |> Repo.insert!()
  end
end
