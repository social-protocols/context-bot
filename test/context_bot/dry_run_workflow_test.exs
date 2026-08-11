defmodule ContextBot.DryRunWorkflowTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.ATProto.PublicClient
  alias ContextBot.DryRun
  alias ContextBot.Research.{AnthropicClient, BudgetEntry}
  alias ContextBot.Settings
  alias ContextBot.Workflow.{Invocation, Store}

  @post_url "https://bsky.app/profile/alice.test/post/invocation"
  @target_uri "at://did:plc:alice/app.bsky.feed.post/invocation"

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_settings = Application.fetch_env!(:context_bot, :settings)
    original_anthropic_client = Application.fetch_env!(:context_bot, AnthropicClient)

    original_thread_worker =
      Application.get_env(:context_bot, ContextBot.Workers.ThreadWorker, :missing)

    original_research_worker =
      Application.get_env(:context_bot, ContextBot.Workers.ResearchWorker, :missing)

    Application.put_env(
      :context_bot,
      AnthropicClient,
      Keyword.update!(original_anthropic_client, :req_options, &Keyword.put(&1, :plugins, []))
    )

    on_exit(fn ->
      Application.put_env(:context_bot, :settings, original_settings)
      Application.put_env(:context_bot, AnthropicClient, original_anthropic_client)
      restore_env(ContextBot.Workers.ThreadWorker, original_thread_worker)
      restore_env(ContextBot.Workers.ResearchWorker, original_research_worker)
    end)

    :ok
  end

  test "a public URL durably becomes a complete local answer without eligibility or publication" do
    settings = Settings.load(anthropic_daily_budget_usd: "20.000000")
    Application.put_env(:context_bot, :settings, settings)
    expect_public_thread()
    public_job = seed_public_thread_job!()

    raw_response = fixture("anthropic/tool_success.json")

    Req.Test.expect(AnthropicClient, fn conn ->
      invocation = Repo.one!(Invocation)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["anthropic-test-key-never-expose"]
      assert conn.body_params["max_tokens"] == 4_096
      assert conn.body_params["output_config"] == %{"effort" => "medium"}

      assert [search, fetch] = conn.body_params["tools"]
      assert search["max_uses"] == 2
      assert search["response_inclusion"] == "excluded"
      refute Map.has_key?(search, "allowed_callers")
      assert fetch["max_uses"] == 2
      assert fetch["max_content_tokens"] == 10_000
      assert fetch["response_inclusion"] == "excluded"
      refute Map.has_key?(fetch, "use_cache")

      assert [message] = conn.body_params["messages"]
      assert message["content"] == invocation.canonical_thread
      assert message["content"] =~ "The root claim."
      assert message["content"] =~ "The immediate parent claim."
      assert message["content"] =~ "[target]\n"
      assert message["content"] =~ "[invocation]\nText:\nWhat's missing?"
      refute message["content"] =~ "DESCENDANT"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.put_resp_header("request-id", "dry-run-test")
      |> Plug.Conn.send_resp(200, raw_response)
    end)

    assert {:ok, invocation, :created} = DryRun.prepare(@post_url, "What's missing?")
    assert invocation.stage == :capturing_thread
    assert invocation.dry_run

    assert queued_jobs() == [
             {"thread", "ContextBot.Workers.ThreadWorker"},
             {"dry_thread", "ContextBot.Workers.ThreadWorker"}
           ]

    perform_and_delete!(:dry_thread)
    thread_ready = Repo.reload!(invocation)
    assert thread_ready.stage == :thread_ready
    assert thread_ready.target_uri == @target_uri
    assert thread_ready.raw_thread == fixture("atproto/thread_ancestors.json")

    assert queued_jobs() == [
             {"thread", "ContextBot.Workers.ThreadWorker"},
             {"dry_research", "ContextBot.Workers.ResearchWorker"}
           ]

    perform_and_delete!(:dry_research)

    assert {:ok, complete} = DryRun.await(invocation, timeout_ms: 0)
    assert complete.stage == :complete
    assert complete.selected_reply == "Useful context from primary sources."
    assert complete.completed_at
    assert complete.reply_repo == nil
    assert complete.reply_rkey == nil
    assert complete.reply_record == nil
    assert complete.reply_uri == nil
    assert complete.reply_cid == nil
    assert complete.anthropic_usage["totals"]["input_tokens"] == 100
    assert complete.anthropic_usage["totals"]["output_tokens"] == 20

    assert [response] = Store.anthropic_responses(complete)
    assert response.raw_body == raw_response

    assert [%BudgetEntry{state: :settled, response_recorded_at: %DateTime{}}] =
             Repo.all(BudgetEntry)

    assert queued_jobs() == [{"thread", "ContextBot.Workers.ThreadWorker"}]
    assert Repo.get!(Oban.Job, public_job.id).state == "available"
    assert Process.whereis(ContextBot.ATProto.Session) == nil
  end

  test "an exhausted daily budget persists deferral without calling Anthropic" do
    settings = Settings.load(anthropic_daily_budget_usd: "5.000000")
    Application.put_env(:context_bot, :settings, settings)
    seed_spent_daily_budget!()
    expect_public_thread()

    Req.Test.stub(AnthropicClient, fn _conn ->
      flunk("Anthropic was called after the daily budget was exhausted")
    end)

    assert {:ok, invocation, :created} = DryRun.prepare(@post_url, "Can you check this?")
    perform_and_delete!(:dry_thread)
    perform_and_delete!(:dry_research)

    assert {:deferred, deferred} = DryRun.await(invocation, timeout_ms: 0)
    assert deferred.stage == :deferred_budget
    assert deferred.defer_until
    assert deferred.selected_reply == nil
    assert Store.anthropic_responses(deferred) == []
    assert Repo.aggregate(BudgetEntry, :count) == 1
    assert queued_jobs() == []
  end

  defp expect_public_thread do
    Req.Test.expect(PublicClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/xrpc/com.atproto.identity.resolveHandle"
      assert URI.decode_query(conn.query_string) == %{"handle" => "alice.test"}
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "atproto-proxy") == []
      Req.Test.json(conn, %{"did" => "did:plc:alice"})
    end)

    Req.Test.expect(PublicClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/xrpc/app.bsky.feed.getPostThread"

      assert URI.decode_query(conn.query_string) == %{
               "depth" => "0",
               "parentHeight" => "80",
               "uri" => @target_uri
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "atproto-proxy") == []
      Req.Test.json(conn, fixture("atproto/thread_ancestors.json"))
    end)
  end

  defp perform_and_delete!(queue) do
    job =
      Oban.Job
      |> where([job], job.queue == ^to_string(queue))
      |> Repo.one!()

    job = %{job | attempt: max(job.attempt, 1), attempted_at: DateTime.utc_now()}

    assert :ok =
             Oban.Testing.perform_job(job,
               repo: Repo,
               engine: Oban.Engines.Lite,
               testing: :manual
             )

    Repo.delete!(Repo.get!(Oban.Job, job.id))
  end

  defp queued_jobs do
    Oban.Job
    |> order_by([job], asc: job.id)
    |> select([job], {job.queue, job.worker})
    |> Repo.all()
  end

  defp seed_public_thread_job! do
    %{"uri" => "at://did:plc:public/app.bsky.feed.post/pending", "cid" => "bafy-public"}
    |> Oban.Job.new(worker: ContextBot.Workers.ThreadWorker, queue: :thread)
    |> Repo.insert!()
  end

  defp seed_spent_daily_budget! do
    prior =
      %Invocation{}
      |> Invocation.changeset(%{
        invocation_uri: "at://did:plc:prior/app.bsky.feed.post/spent-budget",
        notification_cid: "bafy-spent-budget",
        current_cid: "bafy-spent-budget",
        actor_did: "did:plc:prior",
        raw_notification: %{"source" => "budget_fixture"},
        received_at: DateTime.utc_now(),
        status: :complete,
        stage: :complete,
        completed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %BudgetEntry{}
    |> BudgetEntry.changeset(%{
      invocation_id: prior.id,
      attempt_key: "spent-daily-budget",
      budget_date: Date.utc_today(),
      kind: :research,
      reserved_microdollars: 5_000_000,
      settled_microdollars: 5_000_000,
      state: :settled,
      usage: %{}
    })
    |> Repo.insert!()
  end

  defp fixture(relative_path) do
    "../fixtures/#{relative_path}"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> then(fn body ->
      if String.ends_with?(relative_path, ".json") and
           String.starts_with?(relative_path, "atproto/"), do: Jason.decode!(body), else: body
    end)
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, config), do: Application.put_env(:context_bot, module, config)
end
