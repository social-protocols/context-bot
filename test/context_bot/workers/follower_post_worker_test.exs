defmodule ContextBot.Workers.FollowerPostWorkerTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Reply.FollowerPost
  alias ContextBot.Workers.FollowerPostWorker
  alias ContextBot.Workers.ReplyWorkerTest.{PDS, Remote}
  alias ContextBot.Workflow.Invocation

  @bot_did "did:plc:contextbot123"
  @collection "app.bsky.feed.post"
  @now ~U[2026-07-29 13:00:00.123456Z]
  @rkey "3mfollowerlater1"

  setup do
    original_worker = Application.get_env(:context_bot, FollowerPostWorker, :missing)
    original_pds = Application.get_env(:context_bot, PDS, :missing)

    on_exit(fn ->
      restore_env(FollowerPostWorker, original_worker)
      restore_env(PDS, original_pds)
    end)

    :ok
  end

  test "does not put when Reader is not indexed and snoozes" do
    invocation = complete_follower!("wait-index")
    remote = configure_remote()

    configure_worker(reader_check: fn _uri -> :not_indexed end)

    assert {:snooze, seconds} = perform(invocation)
    assert seconds == 15

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.follower_post_uri == nil
    assert persisted.reader_ready_at == nil
    assert persisted.reader_checked_at == @now
    assert Remote.snapshot(remote).calls == []
  end

  test "keeps waiting when the Reader probe is ambiguous" do
    invocation = complete_follower!("wait-ambiguous")
    remote = configure_remote()

    configure_worker(reader_check: fn _uri -> :ambiguous end)

    assert {:snooze, 15} = perform(invocation)
    assert Repo.reload!(invocation).follower_post_uri == nil
    assert Remote.snapshot(remote).calls == []
  end

  test "puts the follower card once Reader reports indexed" do
    created_at = @now
    invocation = complete_follower!("indexed")
    {:ok, record} = FollowerPost.build(invocation, created_at)
    follower_uri = "at://#{@bot_did}/#{@collection}/#{@rkey}"

    remote =
      configure_remote(
        get_results: [
          {:error, :record_not_found},
          {:ok, 200, %{}, %{"uri" => follower_uri, "cid" => "bafy-follower", "value" => record}}
        ],
        put_results: [
          {:ok, 200, %{}, %{"uri" => follower_uri, "cid" => "bafy-follower"}}
        ]
      )

    configure_worker(
      now: fn -> created_at end,
      tid: fn _unix -> @rkey end,
      reader_check: fn uri ->
        assert uri == invocation.standard_site_document_uri
        :indexed
      end
    )

    assert :ok = perform(invocation)

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.follower_post_rkey == @rkey
    assert persisted.follower_post_uri == follower_uri
    assert persisted.follower_post_cid == "bafy-follower"
    assert persisted.reader_ready_at == @now
    refute persisted.follower_post_record["embed"]["media"]["external"]["uri"] =~ "getcontext.bot"

    assert persisted.follower_post_record["embed"]["media"]["external"]["uri"] =~
             "standard-reader.app"

    assert Enum.any?(
             Remote.snapshot(remote).calls,
             &match?({:put, @bot_did, @collection, @rkey, _}, &1)
           )
  end

  test "latched reader_ready_at publishes without probing" do
    invocation = complete_follower!("latched", reader_ready_at: @now, reader_checked_at: @now)
    {:ok, record} = FollowerPost.build(invocation, @now)
    follower_uri = "at://#{@bot_did}/#{@collection}/#{@rkey}"

    remote =
      configure_remote(
        get_results: [
          {:error, :record_not_found},
          {:ok, 200, %{}, %{"uri" => follower_uri, "cid" => "bafy-latched", "value" => record}}
        ],
        put_results: [
          {:ok, 200, %{}, %{"uri" => follower_uri, "cid" => "bafy-latched"}}
        ]
      )

    configure_worker(
      tid: fn _unix -> @rkey end,
      reader_check: fn _uri -> flunk("should not probe after latch") end
    )

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).follower_post_uri == follower_uri
    assert Enum.any?(Remote.snapshot(remote).calls, &match?({:put, _, _, @rkey, _}, &1))
  end

  test "does not put a second follower post when one is already stored" do
    invocation =
      complete_follower!("already",
        follower_post_rkey: @rkey,
        follower_post_record: %{"text" => "existing"},
        follower_post_uri: "at://#{@bot_did}/#{@collection}/#{@rkey}",
        follower_post_cid: "bafy-existing"
      )

    remote = configure_remote()
    configure_worker(reader_check: fn _uri -> :indexed end)

    assert :ok = perform(invocation)
    assert :ok = perform(Repo.reload!(invocation))

    persisted = Repo.reload!(invocation)
    assert persisted.follower_post_uri == "at://#{@bot_did}/#{@collection}/#{@rkey}"
    assert persisted.follower_post_cid == "bafy-existing"
    assert Remote.snapshot(remote).calls == []
  end

  test "skips an ineligible complete invocation without putting" do
    invocation = complete_follower!("no-root", root_uri: nil, root_cid: nil)
    remote = configure_remote()
    configure_worker(reader_check: fn _uri -> flunk("ineligible should not probe") end)

    assert :ok = perform(invocation)
    assert Repo.reload!(invocation).follower_post_uri == nil
    assert Remote.snapshot(remote).calls == []
  end

  test "reconsider enqueues unique jobs for complete invocations waiting on Reader" do
    pending = complete_follower!("reconsider-pending")

    published =
      complete_follower!("reconsider-done",
        follower_post_uri: "at://did:plc:bot/app.bsky.feed.post/done",
        follower_post_cid: "bafy-done"
      )

    configure_worker(now: fn -> @now end)
    assert :ok = FollowerPostWorker.perform(%Oban.Job{args: %{}})

    jobs = Repo.all(Oban.Job)

    assert Enum.any?(
             jobs,
             &(&1.worker == "ContextBot.Workers.FollowerPostWorker" and
                 &1.args["invocation_id"] == pending.id)
           )

    refute Enum.any?(jobs, &(&1.args["invocation_id"] == published.id))
  end

  defp perform(invocation, attempt \\ 1) do
    FollowerPostWorker.perform(%Oban.Job{
      attempt: attempt,
      max_attempts: 20,
      args: %{"invocation_id" => invocation.id}
    })
  end

  defp configure_remote(options \\ []) do
    {:ok, remote} = Remote.start_link(options)

    Application.put_env(:context_bot, PDS, remote: remote)
    remote
  end

  defp configure_worker(overrides) do
    defaults = [
      client: PDS,
      now: fn -> @now end,
      tid: fn unix -> Integer.to_string(unix) end
    ]

    Application.put_env(:context_bot, FollowerPostWorker, Keyword.merge(defaults, overrides))
  end

  defp complete_follower!(suffix, overrides \\ []) do
    root_uri = "at://did:plc:root/app.bsky.feed.post/root-#{suffix}"
    reader_url = "https://standard-reader.app/a/#{@bot_did}/doc-#{suffix}"

    attrs =
      %{
        dry_run: false,
        invocation_uri: "at://did:plc:actor/app.bsky.feed.post/#{suffix}",
        notification_cid: "bafy-#{suffix}",
        current_cid: "bafy-current-#{suffix}",
        actor_did: "did:plc:actor",
        raw_notification: %{
          "record" => %{"text" => "@getcontext.bot what is the evidence?"}
        },
        received_at: DateTime.add(@now, -60),
        status: :complete,
        stage: :complete,
        completed_at: @now,
        selected_reply: "Frozen context for #{suffix}.",
        reply_validation: %{"document_title" => "What Is The Evidence?"},
        reply_repo: @bot_did,
        reply_rkey: "3mreply#{suffix}",
        reply_uri: "at://#{@bot_did}/app.bsky.feed.post/3mreply#{suffix}",
        reply_cid: "bafy-reply",
        root_uri: root_uri,
        root_cid: "bafy-root-#{suffix}",
        standard_site_document_uri: "at://#{@bot_did}/site.standard.document/doc-#{suffix}",
        standard_site_document_cid: FakeSiteCids.document(),
        standard_site_publication_uri: "at://#{@bot_did}/site.standard.publication/context-bot",
        standard_site_publication_cid: FakeSiteCids.publication(),
        reply_record: %{
          "text" => "Frozen context for #{suffix}. (full response)",
          "facets" => [
            %{
              "features" => [
                %{"$type" => "app.bsky.richtext.facet#link", "uri" => reader_url}
              ]
            }
          ]
        }
      }
      |> Map.merge(Map.new(overrides))

    invocation =
      %Invocation{}
      |> Invocation.changeset(attrs)
      |> Repo.insert!()

    cache =
      overrides
      |> Keyword.take([:reader_ready_at, :reader_checked_at])
      |> Map.new()

    if cache == %{} do
      invocation
    else
      invocation
      |> Invocation.reader_index_changeset(cache)
      |> Repo.update!()
    end
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
