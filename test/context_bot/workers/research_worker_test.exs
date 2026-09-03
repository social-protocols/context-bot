defmodule ContextBot.Workers.ResearchWorkerTest.Runner do
  @moduledoc false

  def run(invocation, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)

    send(
      config[:test_pid],
      {:runner_called, invocation.stage, options, ContextBot.Repo.in_transaction?()}
    )

    case config[:result] do
      result when is_function(result, 1) -> result.(invocation)
      result -> result
    end
  end
end

defmodule ContextBot.Workers.ResearchWorkerTest.AnthropicClient do
  @moduledoc false

  alias ContextBot.Repo
  alias ContextBot.Research.{BudgetEntry, Request}

  def send_message(request, metadata) do
    test_pid = Process.get(:research_worker_integration_pid)

    entry = Repo.get_by!(BudgetEntry, attempt_key: metadata.attempt_key)

    send(test_pid, {:integrated_anthropic_call, entry.state, Repo.in_transaction?()})

    raw_body =
      if Request.structure_request?(request) do
        File.read!(Path.expand("../../fixtures/anthropic/structure_success.json", __DIR__))
      else
        Process.get(:research_worker_integration_body)
      end

    {:ok,
     %{
       status: 200,
       headers: %{"content-type" => ["application/json"], "request-id" => ["integrated"]},
       raw_body: raw_body,
       received_at: ~U[2026-07-29 12:34:56.123456Z],
       duration_ms: 12
     }}
  end
end

defmodule ContextBot.Workers.ResearchWorkerTest do
  use ContextBot.DataCase, async: false

  import ExUnit.CaptureLog

  alias ContextBot.ATProto.TID
  alias ContextBot.LimitNoticeRecorder
  alias ContextBot.Research.{ReplyLimits, Request}
  alias ContextBot.Settings
  alias ContextBot.Workers.ResearchWorker
  alias ContextBot.Workers.ResearchWorkerTest.{AnthropicClient, Runner}
  alias ContextBot.Workflow.{Invocation, Store}

  @now ~U[2026-07-29 12:34:56.123456Z]
  @bot_did "did:plc:contextbot123"
  @rkey "3mzzzzzzzzzzz"

  setup do
    original_worker_config = Application.get_env(:context_bot, ResearchWorker, :missing)
    original_runner_config = Application.get_env(:context_bot, Runner, :missing)

    on_exit(fn ->
      restore_env(ResearchWorker, original_worker_config)
      restore_env(Runner, original_runner_config)
      Process.delete(:research_worker_integration_pid)
      Process.delete(:research_worker_integration_body)
    end)

    :ok
  end

  test "integrates the real durable runner and remains idempotent under a duplicate job" do
    invocation = invocation("integrated", :thread_ready)
    body = fixture("tool_success.json")
    Process.put(:research_worker_integration_pid, self())
    Process.put(:research_worker_integration_body, body)

    settings =
      Settings.load(bot_did: @bot_did, anthropic_daily_budget_usd: "20.000000")

    configure_worker(
      runner: ContextBot.Research.Runner,
      runner_options: [
        client: AnthropicClient,
        decoder: &Jason.decode/1,
        now: fn -> @now end,
        sleep: fn _milliseconds -> :ok end
      ],
      settings: settings,
      atproto_client: FakeStandardSiteClient
    )

    assert :ok = perform(invocation)
    assert_received {:integrated_anthropic_call, :sent, false}
    assert_received {:integrated_anthropic_call, :sent, false}

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :reply_ready
    assert persisted.selected_reply == "Useful context from primary sources."
    assert persisted.full_response =~ "Useful context from primary sources."
    assert persisted.standard_site_document_uri =~ "site.standard.document"
    assert [research_response, structure_response] = Store.anthropic_responses(persisted)
    assert research_response.raw_body == body
    assert structure_response.kind == :structure
    assert persisted.reply_record["text"] == persisted.selected_reply <> " (full response)"
    assert [%Oban.Job{worker: "ContextBot.Workers.ReplyWorker"}] = Repo.all(Oban.Job)

    assert :ok = perform(persisted)
    refute_received {:integrated_anthropic_call, _state, _transaction}
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "forwards operator new_attempt as a runner force_new_attempt option" do
    invocation = invocation("new-attempt-flag", :thread_ready)
    configure_runner({:ok, runner_result()})
    configure_worker()

    assert :ok =
             ResearchWorker.perform(%Oban.Job{
               args: %{
                 "uri" => invocation.invocation_uri,
                 "cid" => invocation.notification_cid,
                 "new_attempt" => true
               }
             })

    assert_received {:runner_called, :researching, options, false}
    assert Keyword.get(options, :force_new_attempt) == true
  end

  test "atomically freezes all research evidence and exact reply intent before queuing publication" do
    invocation = invocation("success", :thread_ready)
    configure_runner({:ok, runner_result()})
    configure_worker()

    assert :ok = perform(invocation)
    assert_received {:runner_called, :researching, _options, false}

    persisted = Repo.reload!(invocation)
    assert persisted.status == :reply_ready
    assert persisted.stage == :reply_ready
    assert persisted.anthropic_messages == runner_result().messages
    assert persisted.anthropic_usage == runner_result().usage
    assert persisted.selected_reply == "Frozen concise context."
    assert persisted.reply_validation == %{"repair_used" => false, "result" => "valid"}
    assert Map.get(persisted, :reply_repo) == @bot_did
    assert persisted.reply_rkey == @rkey

    expected_record = %{
      "$type" => "app.bsky.feed.post",
      "text" => "Frozen concise context.",
      "createdAt" => "2026-07-29T12:34:56.123456Z",
      "reply" => %{
        "parent" => %{
          "uri" => invocation.invocation_uri,
          "cid" => invocation.current_cid
        },
        "root" => %{
          "uri" => invocation.root_uri,
          "cid" => invocation.root_cid
        }
      }
    }

    assert persisted.reply_record == expected_record
    assert persisted.reply_part2_rkey == nil
    assert persisted.reply_part2_record == nil

    assert [%Oban.Job{} = reply_job] = Repo.all(Oban.Job)
    assert reply_job.worker == "ContextBot.Workers.ReplyWorker"
    assert reply_job.queue == "reply"
    assert reply_job.state == "available"

    assert reply_job.args == %{
             "uri" => invocation.invocation_uri,
             "cid" => invocation.notification_cid
           }

    # The future PDS worker can only become visible in the same commit as this queryable intent.
    assert Repo.get!(Invocation, invocation.id).reply_record == expected_record
  end

  test "freezes a two-post intent only when the runner result includes text_part2" do
    invocation = invocation("split-success", :thread_ready)
    part1 = String.duplicate("a", 150)
    part2 = String.duplicate("b", 160)

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:text, part1)
       |> Map.put(:text_part2, part2)
       |> Map.put(:validation, %{
         "result" => "split",
         "repair_used" => false,
         "part1_graphemes" => 150,
         "part2_graphemes" => 160
       })}
    )

    {:ok, agent} = Agent.start_link(fn -> ["3mpart1rkey111", "3mpart2rkey222"] end)

    configure_worker(
      tid_generator: fn _timestamp ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end
    )

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    ellipsis = ReplyLimits.continuation_ellipsis()
    assert persisted.selected_reply == part1
    assert persisted.reply_record["text"] == part1 <> ellipsis
    assert persisted.reply_part2_rkey == "3mpart2rkey222"
    assert persisted.reply_part2_record["text"] == ellipsis <> part2
  end

  test "creates a missing publication then a document and freezes the reader URL" do
    invocation =
      invocation("full-response-compact", :thread_ready, %{
        raw_notification: %{
          "uri" => "at://did:plc:actor/app.bsky.feed.post/full-response-compact",
          "cid" => "bafy-full-response-compact",
          "record" => %{
            "$type" => "app.bsky.feed.post",
            "text" => "@getcontext.bot What bird is that?",
            "reply" => %{
              "parent" => %{"uri" => "at://did:plc:bob/app.bsky.feed.post/3parentrkey12"}
            }
          }
        }
      })

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:full_response, "Thorough markdown writeup.")
       |> Map.put(:document_title, "What Is That Bird?")}
    )

    configure_worker(atproto_client: FakeStandardSiteTrackingClient)

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)

    assert_received {:standard_site_get, "site.standard.publication", "context-bot"}
    assert_received {:standard_site_put, "site.standard.publication", "context-bot", pub_record}
    assert pub_record["$type"] == "site.standard.publication"

    prompt_rkey = Request.system_prompt_rkey()
    assert_received {:standard_site_get, "site.standard.document", ^prompt_rkey}
    assert_received {:standard_site_put, "site.standard.document", ^prompt_rkey, prompt_record}
    assert prompt_record["$type"] == "site.standard.document"
    assert prompt_record["textContent"] == Request.system_prompt()

    assert_received {:standard_site_put, "site.standard.document", doc_rkey, doc_record}
    assert is_binary(doc_rkey) and doc_rkey != ""
    assert doc_rkey != prompt_rkey
    assert doc_record["$type"] == "site.standard.document"
    assert doc_record["textContent"] == "Thorough markdown writeup."
    assert doc_record["title"] == "What Is That Bird?"
    assert doc_record["description"] == "@getcontext.bot What bird is that?"
    refute doc_record["title"] =~ "Context on"
    refute doc_record["description"] == "What bird is that?"

    markdown = doc_record["content"]["text"]["markdown"]
    responding = responding_block(markdown)

    refute markdown =~ "## Asked"
    refute responding =~ "@getcontext.bot What bird is that?"

    assert responding ==
             "Responding to [@did:plc:actor](https://bsky.app/profile/did:plc:actor/post/full-response-compact)'s reply to [@did:plc:bob](https://bsky.app/profile/did:plc:bob/post/3parentrkey12)'s post."

    assert markdown =~ "Thorough markdown writeup."
    assert markdown =~ Request.system_prompt_id()
    assert markdown =~ Request.system_prompt_sha256()
    assert markdown =~ "https://standard-reader.app/a/#{@bot_did}/#{prompt_rkey}"
    assert markdown =~ "`anthropic-version`: 2023-06-01"
    assert markdown =~ "`model`: claude-sonnet-5"
    assert markdown =~ "canonical thread"
    assert markdown =~ "Hidden model reasoning is not available"
    assert markdown =~ "[Continue this conversation in Claude](https://claude.ai/new?q="

    reader_url = "https://standard-reader.app/a/#{@bot_did}/#{doc_rkey}"

    assert [_, href] =
             Regex.run(
               ~r/\[Continue this conversation in Claude\]\((https:\/\/claude\.ai\/new\?q=[^)]+)\)/,
               markdown
             )

    %URI{query: query} = URI.parse(href)
    assert %{"q" => starter} = URI.decode_query(query)
    assert starter =~ reader_url
    refute starter =~ "Thorough markdown writeup."
    refute starter =~ Request.system_prompt()
    refute href =~ "attachment="
    refute href =~ "claude://"

    assert persisted.full_response == "Thorough markdown writeup."

    assert persisted.standard_site_document_uri ==
             "at://#{@bot_did}/site.standard.document/#{doc_rkey}"

    assert persisted.standard_site_document_rkey == doc_rkey
    assert persisted.failure_detail == nil
    assert persisted.reply_record["text"] == "Frozen concise context. (full response)"
    assert [facet] = persisted.reply_record["facets"]

    assert hd(facet["features"])["uri"] ==
             "https://standard-reader.app/a/#{@bot_did}/#{doc_rkey}"
  end

  test "fails closed without freezing a reply when publication create fails" do
    invocation = invocation("publication-lexicon-unknown", :thread_ready)

    configure_runner(
      {:ok, runner_result() |> Map.put(:full_response, "Thorough markdown writeup.")}
    )

    configure_worker(atproto_client: FakeStandardSiteLexiconUnknown)
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :warning, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.status == :failed
    assert persisted.failure_category == :provider_response
    assert persisted.full_response == "Thorough markdown writeup."
    assert persisted.selected_reply == "Frozen concise context."
    assert persisted.standard_site_document_uri == nil
    assert persisted.standard_site_document_rkey == nil
    assert persisted.reply_rkey == nil
    assert persisted.reply_record == nil
    assert persisted.failure_detail["reason"] == "standard_site_document_failed"
    assert persisted.failure_detail["collection"] == "site.standard.publication"
    assert persisted.failure_detail["status"] == 400
    assert persisted.failure_detail["error"] == "InvalidRequest"
    assert persisted.failure_detail["message"] == "Lexicon not found: site.standard.publication"
    assert Repo.all(Oban.Job) == []

    decoded = Jason.decode!(log)
    assert decoded["message"] == "context_bot_standard_site"
    assert decoded["invocation_id"] == invocation.id
    assert decoded["collection"] == "site.standard.publication"
    assert decoded["status_code"] == 400
    assert decoded["atproto_error"] == "InvalidRequest"
    assert decoded["failure_reason"] == "permanent"
    assert decoded["atproto_message"] == "Lexicon not found: site.standard.publication"
    refute log =~ invocation.invocation_uri
    refute log =~ "Thorough markdown writeup"
  end

  test "fails closed without freezing a reply when the prompt document cannot be created" do
    invocation = invocation("prompt-document-create-fails", :thread_ready)

    configure_runner(
      {:ok, runner_result() |> Map.put(:full_response, "Thorough markdown writeup.")}
    )

    configure_worker(atproto_client: FakePublicationExistsDocumentFails)

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.standard_site_document_uri == nil
    assert persisted.reply_record == nil
    assert persisted.failure_detail["reason"] == "standard_site_document_failed"
    assert persisted.failure_detail["collection"] == "site.standard.document"
    assert Repo.all(Oban.Job) == []
  end

  test "fails closed without freezing a reply when the publication exists but document create fails" do
    invocation = invocation("document-lexicon-unknown", :thread_ready)

    configure_runner(
      {:ok, runner_result() |> Map.put(:full_response, "Thorough markdown writeup.")}
    )

    configure_worker(atproto_client: FakePublicationAndPromptExistDocumentFails)

    log =
      capture_log(
        [level: :warning, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    persisted = Repo.reload!(invocation)
    assert persisted.stage == :failed
    assert persisted.failure_category == :provider_response
    assert persisted.full_response == "Thorough markdown writeup."
    assert persisted.standard_site_document_uri == nil
    assert persisted.reply_record == nil
    assert persisted.failure_detail["collection"] == "site.standard.document"
    assert persisted.failure_detail["status"] == 400
    assert persisted.failure_detail["error"] == "InvalidRequest"
    assert Repo.all(Oban.Job) == []
    assert log =~ "context_bot_standard_site"
    assert log =~ "site.standard.document"
  end

  test "publishes a Standard.site document and remainder-plus-link part 2 when a split keeps a full response" do
    invocation = invocation("split-full-response", :thread_ready)
    part1 = String.duplicate("a", 150)
    part2 = String.duplicate("b", 160)

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:text, part1)
       |> Map.put(:text_part2, part2)
       |> Map.put(:full_response, "Thorough markdown writeup.")
       |> Map.put(:validation, %{
         "result" => "split",
         "repair_used" => false,
         "part1_graphemes" => 150,
         "part2_graphemes" => 160
       })}
    )

    {:ok, agent} = Agent.start_link(fn -> ["3mpart1rkey111", "3mpart2rkey222"] end)

    configure_worker(
      atproto_client: FakeStandardSiteClient,
      tid_generator: fn _timestamp ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end
    )

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    ellipsis = ReplyLimits.continuation_ellipsis()
    assert persisted.full_response == "Thorough markdown writeup."
    assert persisted.standard_site_document_uri =~ "site.standard.document"
    assert persisted.reply_record["text"] == part1 <> ellipsis
    assert persisted.reply_part2_record["text"] == ellipsis <> part2
    assert persisted.reply_part2_record["readerUrl"] =~ "https://standard-reader.app/a/"
  end

  test "completes a dry run with all research evidence and no publication intent" do
    invocation =
      invocation("dry-success", :thread_ready, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/selected",
        invocation_text: "Is this fair?"
      })

    configure_runner({:ok, runner_result()})

    configure_worker(
      settings: Settings.load(anthropic_daily_budget_usd: "20.000000"),
      reply_job_builder: fn _invocation -> flunk("dry run constructed a reply job") end,
      tid_generator: fn _timestamp -> flunk("dry run constructed a publication key") end
    )

    assert :ok = perform(invocation)
    assert_received {:runner_called, :researching, _options, false}

    persisted = Repo.reload!(invocation)
    assert persisted.status == :complete
    assert persisted.stage == :complete
    assert persisted.completed_at == @now
    assert persisted.anthropic_messages == runner_result().messages
    assert persisted.anthropic_usage == runner_result().usage
    assert persisted.selected_reply == "Frozen concise context."
    assert persisted.reply_validation == %{"repair_used" => false, "result" => "valid"}
    assert persisted.reply_repo == nil
    assert persisted.reply_rkey == nil
    assert persisted.reply_record == nil
    assert persisted.publication_claim_token == nil
    assert persisted.publication_claimed_at == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a dry-run split stores the remainder for local display without a reply intent" do
    invocation =
      invocation("dry-split", :thread_ready, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/selected",
        invocation_text: "Is this fair?"
      })

    part1 = String.duplicate("a", 150)
    part2 = String.duplicate("b", 160)

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:text, part1)
       |> Map.put(:text_part2, part2)
       |> Map.put(:full_response, "Thorough markdown writeup.")
       |> Map.put(:validation, %{
         "result" => "split",
         "repair_used" => false,
         "part1_graphemes" => 150,
         "part2_graphemes" => 160
       })}
    )

    configure_worker(
      settings: Settings.load(anthropic_daily_budget_usd: "20.000000"),
      reply_job_builder: fn _invocation -> flunk("dry run constructed a reply job") end,
      tid_generator: fn _timestamp -> flunk("dry run constructed a publication key") end
    )

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.selected_reply == part1
    assert persisted.full_response == "Thorough markdown writeup."
    assert persisted.reply_validation["text_part2"] == part2
    assert persisted.reply_record == nil
    assert persisted.reply_part2_record == nil
    assert persisted.reply_rkey == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "logs a research attempt without provider or invocation content" do
    invocation = invocation("logged-research", :thread_ready)
    configure_runner({:ok, runner_result()})
    configure_worker()
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log(
        [level: :info, formatter: {ContextBot.Logging.JSONFormatter, %{}}],
        fn -> assert :ok = perform(invocation) end
      )

    assert log =~ "\"invocation_id\":#{invocation.id}"
    assert log =~ "\"stage\":\"researching\""
    assert log =~ "\"attempt_kind\":\"research\""
    refute log =~ invocation.invocation_uri
    refute log =~ "Frozen concise context"
  end

  test "rolls back reply evidence and job together when publication enqueue fails" do
    invocation = invocation("rollback", :thread_ready)
    configure_runner({:ok, runner_result()})

    invalid_job_builder = fn claimed ->
      %{"uri" => claimed.invocation_uri, "cid" => claimed.notification_cid}
      |> Oban.Job.new(worker: "ContextBot.Workers.ReplyWorker", queue: :reply)
      |> Ecto.Changeset.add_error(:args, "forced reply handoff failure")
    end

    configure_worker(reply_job_builder: invalid_job_builder)

    assert_raise Ecto.InvalidChangesetError, fn -> perform(invocation) end
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :researching
    assert persisted.selected_reply == nil
    assert persisted.reply_rkey == nil
    assert persisted.reply_record == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "defers exhausted budget through the next UTC rollover without reply work" do
    invocation = invocation("budget", :thread_ready)
    rollover = ~U[2026-07-30 00:00:00.000000Z]
    configure_runner({:deferred, rollover})
    configure_worker()

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.status == :deferred_budget
    assert persisted.defer_until == rollover
    assert persisted.reply_record == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "claims eligible deferred work, resumes researching, and ignores future or completed work" do
    eligible =
      invocation("eligible-deferred", :deferred_budget, %{defer_until: DateTime.add(@now, -1)})

    configure_runner({:ok, runner_result()})
    configure_worker(tid_generator: &TID.generate/1)
    assert :ok = perform(eligible)
    assert Repo.reload!(eligible).stage == :reply_ready

    future =
      invocation("future-deferred", :deferred_budget, %{defer_until: DateTime.add(@now, 60)})

    assert :ok = perform(future)
    assert Repo.reload!(future).stage == :deferred_budget

    researching = invocation("resume", :researching)
    assert :ok = perform(researching)
    assert Repo.reload!(researching).stage == :reply_ready

    complete = invocation("complete", :complete)
    assert :ok = perform(complete)
    assert Repo.reload!(complete).stage == :complete

    assert_received {:runner_called, :researching, _options, false}
    assert_received {:runner_called, :researching, _options, false}
    refute_received {:runner_called, _stage, _options, _transaction}
  end

  test "only one duplicate job can own an already researching invocation" do
    invocation = invocation("concurrent-researching", :researching)
    test_pid = self()
    rollover = ~U[2026-07-30 00:00:00.000000Z]

    configure_runner(fn _invocation ->
      send(test_pid, {:runner_at_barrier, self()})

      receive do
        :release_runner -> {:deferred, rollover}
      after
        1_000 -> {:deferred, rollover}
      end
    end)

    configure_worker()

    tasks =
      for job_id <- [101, 102] do
        Task.async(fn -> perform(invocation, job_id) end)
      end

    assert_receive {:runner_called, :researching, _options, false}
    assert_receive {:runner_at_barrier, runner_pid}
    refute_receive {:runner_called, :researching, _options, false}, 100

    send(runner_pid, :release_runner)
    assert Task.await_many(tasks) == [:ok, :ok]
    assert Repo.reload!(invocation).stage == :deferred_budget
  end

  test "the same Oban job resumes its lease after a crash while a duplicate remains blocked" do
    invocation = invocation("lease-resume", :researching)
    configure_runner(fn _invocation -> raise "injected runner crash" end)
    configure_worker()

    assert_raise RuntimeError, "injected runner crash", fn -> perform(invocation, 201) end
    assert_received {:runner_called, :researching, options, false}
    assert options[:claim_token] == "research-job-201"
    assert Repo.reload!(invocation).research_claim_token == "research-job-201"

    rollover = ~U[2026-07-30 00:00:00.000000Z]
    configure_runner({:deferred, rollover})

    assert :ok = perform(invocation, 202)
    refute_received {:runner_called, _stage, _options, _transaction}

    assert :ok = perform(invocation, 201)
    assert_received {:runner_called, :researching, resumed_options, false}
    assert resumed_options[:claim_token] == "research-job-201"
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.research_claim_token == nil
    assert persisted.research_claimed_at == nil
  end

  test "a different Oban job can take over a stale research lease" do
    invocation = invocation("stale-lease", :researching)
    configure_runner(fn _invocation -> raise "injected runner crash" end)
    configure_worker(claim_lease_ms: 1_000)

    assert_raise RuntimeError, "injected runner crash", fn -> perform(invocation, 301) end
    assert_received {:runner_called, :researching, _options, false}
    assert Repo.reload!(invocation).research_claim_token == "research-job-301"

    rollover = ~U[2026-07-30 00:00:00.000000Z]
    configure_runner({:deferred, rollover})

    configure_worker(
      now: fn -> DateTime.add(@now, 1_001, :millisecond) end,
      claim_lease_ms: 1_000
    )

    assert :ok = perform(invocation, 302)
    assert_received {:runner_called, :researching, _options, false}
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.research_claim_token == nil
    assert persisted.research_claimed_at == nil
  end

  test "a stale worker cannot win final, defer, or fail after another job takes over" do
    outcomes = [
      {"final", {:ok, runner_result()}},
      {"defer", {:deferred, ~U[2026-07-30 00:00:00.000000Z]}},
      {"fail", {:error, :provider_auth}}
    ]

    for {suffix, outcome} <- outcomes do
      invocation = invocation("stale-terminal-#{suffix}", :researching)
      new_token = "research-job-new-#{suffix}"

      configure_runner(fn claimed ->
        assert {:ok, taken_over} =
                 Store.claim_research(
                   claimed,
                   new_token,
                   DateTime.add(@now, 2, :second),
                   DateTime.add(@now, 1, :second)
                 )

        assert taken_over.research_claim_token == new_token
        outcome
      end)

      configure_worker(claim_lease_ms: 1_000)

      assert :ok = perform(invocation, 401)
      persisted = Repo.reload!(invocation)
      assert persisted.stage == :researching
      assert persisted.research_claim_token == new_token
      assert persisted.selected_reply == nil
      assert persisted.failure_category == nil
      assert persisted.defer_until == nil
    end

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "snoozes when the runner is waiting out an in-flight provider attempt" do
    invocation = invocation("wait-inflight", :researching)
    configure_runner({:wait, 5_001})
    configure_worker()

    assert {:snooze, 6} = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :researching
    assert persisted.failure_category == nil
    assert persisted.completed_at == nil
  end

  test "maps terminal runner states to finite silent provider failures" do
    for {suffix, runner_error, category} <- [
          {"auth", :provider_auth, :provider_auth},
          {"malformed", :malformed_provider_response, :provider_response},
          {"interrupted", :interrupted_after_send, :provider_response},
          {"tool-cap", :tool_use_limit_exceeded, :provider_response},
          {"code-exec", :code_execution_failed, :provider_response}
        ] do
      invocation = invocation(suffix, :thread_ready)
      configure_runner({:error, runner_error})
      configure_worker()

      assert :ok = perform(invocation)
      persisted = Repo.reload!(invocation)
      assert persisted.stage == :failed
      assert persisted.failure_category == category
      assert persisted.failure_detail == %{"reason" => Atom.to_string(runner_error)}
      assert persisted.completed_at == @now
      assert persisted.reply_record == nil
    end

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "posts the funding notice once when the daily budget is exhausted" do
    invocation = invocation("budget-notice", :thread_ready)
    rollover = ~U[2026-07-30 00:00:00.000000Z]
    configure_runner({:deferred, rollover})
    configure_worker(limit_notice: LimitNoticeRecorder)

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :deferred_budget
    assert persisted.admitted_at == nil or persisted.reply_record == nil
    assert_received {:limit_notice, :budget, id}
    assert id == invocation.id
    refute_received {:limit_notice, :budget, _}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "completes a no-reply result without Bluesky, Standard.site, or a public failure" do
    invocation = invocation("no-reply", :thread_ready)

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:disposition, :no_reply)
       |> Map.put(:text, "")
       |> Map.delete(:full_response)
       |> Map.put(:validation, %{"result" => "no_reply", "repair_used" => false})}
    )

    configure_worker(
      atproto_client: FakeStandardSiteTrackingClient,
      limit_notice: LimitNoticeRecorder,
      reply_job_builder: fn _invocation -> flunk("no-reply constructed a reply job") end,
      tid_generator: fn _timestamp -> flunk("no-reply constructed a publication key") end
    )

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.status == :complete
    assert persisted.stage == :complete
    assert persisted.completed_at == @now
    assert persisted.no_reply == true
    assert persisted.selected_reply == nil
    assert persisted.full_response == nil
    assert persisted.reply_validation == %{"result" => "no_reply", "repair_used" => false}
    assert persisted.reply_repo == nil
    assert persisted.reply_rkey == nil
    assert persisted.reply_record == nil
    assert persisted.standard_site_document_uri == nil
    assert persisted.standard_site_document_rkey == nil
    assert persisted.failure_category == nil
    assert persisted.failure_detail == nil
    refute_received {:standard_site_get, _, _}
    refute_received {:standard_site_put, _, _, _}
    refute_received {:limit_notice, _, _}
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "completes a dry-run no-reply without inventing a compact or document" do
    invocation =
      invocation("dry-no-reply", :thread_ready, %{
        dry_run: true,
        target_uri: "at://did:plc:target/app.bsky.feed.post/selected",
        invocation_text: "getcontext.bot is great"
      })

    configure_runner(
      {:ok,
       runner_result()
       |> Map.put(:disposition, :no_reply)
       |> Map.put(:text, "")
       |> Map.put(:validation, %{"result" => "no_reply", "repair_used" => false})}
    )

    configure_worker(
      settings: Settings.load(anthropic_daily_budget_usd: "20.000000"),
      reply_job_builder: fn _invocation -> flunk("dry no-reply constructed a reply job") end,
      tid_generator: fn _timestamp -> flunk("dry no-reply constructed a publication key") end
    )

    assert :ok = perform(invocation)
    persisted = Repo.reload!(invocation)
    assert persisted.stage == :complete
    assert persisted.no_reply == true
    assert persisted.selected_reply == nil
    assert persisted.full_response == nil
    assert persisted.reply_record == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "does not post a limit notice on structured-output or other research failures" do
    for {suffix, runner_error} <- [
          {"structured", :invalid_structured_output},
          {"auth-notice", :provider_auth},
          {"code-exec-notice", :code_execution_failed}
        ] do
      invocation = invocation(suffix, :thread_ready)
      configure_runner({:error, runner_error})
      configure_worker(limit_notice: LimitNoticeRecorder)

      assert :ok = perform(invocation)
      assert Repo.reload!(invocation).stage == :failed
      refute_received {:limit_notice, _, _}
    end
  end

  defp configure_runner(result) do
    Application.put_env(:context_bot, Runner, test_pid: self(), result: result)
  end

  defp configure_worker(overrides \\ []) do
    defaults = [
      now: fn -> @now end,
      limit_notice: ContextBot.LimitNoticeNoop,
      reply_job_builder: nil,
      runner: Runner,
      runner_options: [evidence: :runner_options_forwarded],
      settings: Settings.load(bot_did: @bot_did),
      tid_generator: fn timestamp_us ->
        assert timestamp_us == DateTime.to_unix(@now, :microsecond)
        @rkey
      end
    ]

    config = Keyword.merge(defaults, overrides)

    config =
      if is_nil(config[:reply_job_builder]) do
        Keyword.delete(config, :reply_job_builder)
      else
        config
      end

    Application.put_env(:context_bot, ResearchWorker, config)
  end

  defp perform(invocation) do
    perform(invocation, nil)
  end

  defp perform(invocation, job_id) do
    ResearchWorker.perform(%Oban.Job{
      id: job_id,
      args: %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
    })
  end

  defp runner_result do
    %{
      messages: %{
        "model" => "claude-sonnet-5",
        "messages" => [%{"role" => "user", "content" => "canonical thread"}]
      },
      usage: %{
        "attempts" => [
          %{
            "attempt_key" => "invocation-1-attempt-1-research",
            "kind" => "research",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }
        ],
        "continuations" => 0,
        "response_count" => 1,
        "tool_uses" => 0,
        "totals" => %{"input_tokens" => 10, "output_tokens" => 5}
      },
      text: "Frozen concise context.",
      validation: %{"repair_used" => false, "result" => "valid"}
    }
  end

  defp fixture(name) do
    "../../fixtures/anthropic/#{name}"
    |> Path.expand(__DIR__)
    |> File.read!()
  end

  defp invocation(suffix, stage, extra \\ %{}) do
    uri = "at://did:plc:actor/app.bsky.feed.post/#{suffix}"
    cid = "bafy-#{suffix}"
    root_uri = "at://did:plc:root/app.bsky.feed.post/root-#{suffix}"

    attrs =
      Map.merge(
        %{
          invocation_uri: uri,
          notification_cid: cid,
          current_cid: "#{cid}-current",
          actor_did: "did:plc:actor",
          raw_notification: %{"uri" => uri, "cid" => cid},
          received_at: DateTime.add(@now, -60),
          status: stage,
          stage: stage,
          canonical_thread: "ROOT\nClaim.\n\nINVOCATION\nPlease add context.",
          canonical_thread_version: "1",
          root_uri: root_uri,
          root_cid: "bafy-root-#{suffix}"
        },
        extra
      )

    %Invocation{}
    |> Invocation.changeset(attrs)
    |> Repo.insert!()
  end

  defp responding_block(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(&1, "Responding to "))
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
