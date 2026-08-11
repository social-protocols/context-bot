defmodule ContextBot.Workflow.StoreTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Research.{Budget, ResponseEnvelope}
  alias ContextBot.Workflow.{Failure, Invocation, Store}
  alias Ecto.Adapters.SQL
  alias Ecto.Query

  defmodule Worker do
    use Oban.Worker, queue: :eligibility

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  @received_at DateTime.from_naive!(~N[2026-07-29 12:00:00.123456], "Etc/UTC")
  @statuses [
    :received,
    :deferred_capacity,
    :checking_eligibility,
    :ineligible,
    :deferred_rate,
    :capturing_thread,
    :thread_ready,
    :deferred_budget,
    :researching,
    :reply_ready,
    :publishing,
    :complete,
    :failed
  ]

  test "stores a strong-reference receipt once and doesn't duplicate its job" do
    mention = mention("at://did:plc:actor/app.bsky.feed.post/first", "bafy-notification")
    job = Worker.new(%{"receipt" => "first"})

    assert {:ok, inserted, :inserted} = Store.receive_mention(mention, @received_at, job)
    assert {:ok, duplicate, :duplicate} = Store.receive_mention(mention, @received_at, job)

    assert duplicate.id == inserted.id
    assert inserted.invocation_uri == mention.uri
    assert inserted.notification_cid == mention.cid
    assert inserted.current_cid == mention.cid
    assert inserted.raw_notification == mention.raw
    assert inserted.status == :received
    assert inserted.stage == :received
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "attaches to the newest matching nonterminal dry run without inserting another job" do
    target_uri = "at://did:plc:target/app.bsky.feed.post/attach-newest"

    assert {:ok, first, :created} =
             Store.create_or_attach_dry_run(target_uri, "Question", @received_at, &thread_job/2)

    newer = DateTime.add(@received_at, 1, :second)
    duplicate = dry_invocation!(target_uri, "Question", newer, :thread_ready)

    assert {:ok, attached, :attached} =
             Store.create_or_attach_dry_run(target_uri, "Question", @received_at, &thread_job/2)

    assert attached.id == duplicate.id
    assert attached.id != first.id
    assert Repo.aggregate(Invocation, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "creates a new run after every matching terminal stage" do
    for stage <- [:complete, :failed, :ineligible] do
      target_uri = "at://did:plc:target/app.bsky.feed.post/attach-terminal-#{stage}"
      terminal = dry_invocation!(target_uri, "Question", @received_at, stage)

      assert {:ok, created, :created} =
               Store.create_or_attach_dry_run(target_uri, "Question", @received_at, &thread_job/2)

      assert created.id != terminal.id
    end

    assert Repo.aggregate(Invocation, :count) == 6
    assert Repo.aggregate(Oban.Job, :count) == 3
  end

  test "creates a distinct run when the question differs exactly" do
    target_uri = "at://did:plc:target/app.bsky.feed.post/attach-question"
    dry_invocation!(target_uri, "Question", @received_at, :thread_ready)

    assert {:ok, created, :created} =
             Store.create_or_attach_dry_run(target_uri, "Question?", @received_at, &thread_job/2)

    assert created.invocation_text == "Question?"
    assert Repo.aggregate(Invocation, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "does not attach to a public invocation with the same target and question" do
    target_uri = "at://did:plc:target/app.bsky.feed.post/attach-public"
    public = dry_invocation!(target_uri, "Question", @received_at, :thread_ready, dry_run: false)

    assert {:ok, created, :created} =
             Store.create_or_attach_dry_run(target_uri, "Question", @received_at, &thread_job/2)

    assert created.id != public.id
    assert created.dry_run
    assert Repo.aggregate(Invocation, :count) == 2
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "rejects invalid dry-run inputs before inserting a row or job" do
    target_uri = "at://did:plc:target/app.bsky.feed.post/3invalid"

    for invalid <- ["", "  \n\t", <<255>>, String.duplicate("x", 10_001)] do
      assert {:error, :invalid_input} =
               Store.create_or_attach_dry_run(target_uri, invalid, @received_at, &thread_job/2)
    end

    assert {:error, :invalid_input} =
             Store.create_or_attach_dry_run("", "Question", @received_at, &thread_job/2)

    assert Repo.aggregate(Invocation, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "treats a new CID at the same URI as a distinct receipt" do
    uri = "at://did:plc:actor/app.bsky.feed.post/edited"

    assert {:ok, first, :inserted} =
             Store.receive_mention(mention(uri, "bafy-version-one"), @received_at, nil)

    assert {:ok, second, :inserted} =
             Store.receive_mention(mention(uri, "bafy-version-two"), @received_at, nil)

    refute first.id == second.id
    assert Repo.aggregate(Invocation, :count) == 2
  end

  test "rejects changes to an existing receipt's durable identity" do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/immutable", "bafy-immutable"),
               @received_at,
               nil
             )

    changeset =
      Invocation.changeset(invocation, %{
        invocation_uri: "at://did:plc:actor/app.bsky.feed.post/replaced",
        notification_cid: "bafy-replaced"
      })

    refute changeset.valid?
    assert errors_on(changeset).invocation_uri == ["is immutable"]
    assert errors_on(changeset).notification_cid == ["is immutable"]
    assert {:error, rejected} = Repo.update(changeset)
    assert errors_on(rejected).invocation_uri == ["is immutable"]
    assert errors_on(rejected).notification_cid == ["is immutable"]

    persisted = Repo.reload!(invocation)
    assert persisted.invocation_uri == "at://did:plc:actor/app.bsky.feed.post/immutable"
    assert persisted.notification_cid == "bafy-immutable"
  end

  test "keeps dry-run identity and publication safety fields immutable" do
    target_uri = "at://did:plc:actor/app.bsky.feed.post/dry-immutable"

    assert {:ok, invocation, :created} =
             Store.create_or_attach_dry_run(
               target_uri,
               "What's missing?",
               @received_at,
               &thread_job/2
             )

    changeset =
      Invocation.changeset(invocation, %{
        dry_run: false,
        target_uri: "at://did:plc:actor/app.bsky.feed.post/replaced",
        invocation_text: "A different question"
      })

    refute changeset.valid?
    assert errors_on(changeset).dry_run == ["is immutable"]
    assert errors_on(changeset).target_uri == ["is immutable"]
    assert errors_on(changeset).invocation_text == ["is immutable"]

    persisted = Repo.reload!(invocation)
    assert persisted.dry_run
    assert persisted.target_uri == target_uri
    assert persisted.invocation_text == "What's missing?"
  end

  test "preserves the notification CID when the current record CID changes" do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/current", "bafy-notified"),
               @received_at,
               nil
             )

    assert {:ok, transitioned} =
             Store.transition(
               invocation,
               :deferred_capacity,
               :capturing_thread,
               %{current_cid: "bafy-current"},
               nil
             )

    assert transitioned.notification_cid == "bafy-notified"
    assert transitioned.current_cid == "bafy-current"
  end

  test "validates exactly the explicit workflow statuses" do
    assert Invocation.statuses() == @statuses

    base_attrs = %{
      invocation_uri: "at://did:plc:actor/app.bsky.feed.post/status",
      notification_cid: "bafy-status",
      current_cid: "bafy-status",
      actor_did: "did:plc:actor",
      raw_notification: %{},
      received_at: @received_at,
      status: :received,
      stage: :received
    }

    assert Invocation.changeset(struct(Invocation), base_attrs).valid?

    refute Invocation.changeset(struct(Invocation), %{base_attrs | status: :unknown}).valid?
  end

  test "compares the persisted stage and atomically hands off to the next job" do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/transition", "bafy-transition"),
               @received_at,
               Worker.new(%{"stage" => "eligibility"})
             )

    next_job = Worker.new(%{"stage" => "thread"}, queue: :thread)

    assert {:ok, transitioned} =
             Store.transition(
               invocation,
               :received,
               :capturing_thread,
               %{eligibility_method: "operator_allowlist", admitted_at: @received_at},
               next_job
             )

    assert transitioned.status == :capturing_thread
    assert transitioned.stage == :capturing_thread
    assert transitioned.eligibility_method == "operator_allowlist"
    assert Repo.aggregate(Oban.Job, :count) == 2

    assert {:error, :stale_stage} =
             Store.transition(
               invocation,
               :received,
               :researching,
               %{canonical_thread: "must not commit"},
               Worker.new(%{"stage" => "research"}, queue: :research)
             )

    persisted = Repo.get!(Invocation, invocation.id)
    assert persisted.status == :capturing_thread
    assert persisted.canonical_thread == nil
    assert Repo.aggregate(Oban.Job, :count) == 2
  end

  test "rolls back a stage update when the next Oban job is invalid" do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/rollback", "bafy-rollback"),
               @received_at,
               nil
             )

    invalid_job =
      %{"stage" => "thread"}
      |> Worker.new(queue: :thread)
      |> Ecto.Changeset.add_error(:args, "forced failure")

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Store.transition(
               invocation,
               :deferred_capacity,
               :capturing_thread,
               %{eligibility_method: "operator_allowlist"},
               invalid_job
             )

    persisted = Repo.get!(Invocation, invocation.id)
    assert persisted.status == :deferred_capacity
    assert persisted.eligibility_method == nil
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "counts only unfinished invocations against pending capacity" do
    assert {:ok, first, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/capacity-1", "bafy-capacity-1"),
               @received_at,
               nil
             )

    assert {:ok, _second, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/capacity-2", "bafy-capacity-2"),
               @received_at,
               nil
             )

    refute Store.pending_capacity_available?(2)
    assert Store.pending_capacity_available?(3)

    assert {:ok, failed} = Store.fail(first, :thread_unavailable, %{reason: "gone"})
    assert failed.status == :failed
    assert failed.failure_category == :thread_unavailable
    assert Store.pending_capacity_available?(2)
  end

  test "recognizes a durable receipt by its URI and notification CID" do
    uri = "at://did:plc:actor/app.bsky.feed.post/known"
    cid = "bafy-known"

    refute Store.received?(uri, cid)

    assert {:ok, _invocation, :inserted} =
             Store.receive_mention(mention(uri, cid), @received_at, nil)

    assert Store.received?(uri, cid)
    refute Store.received?(uri, "bafy-new-version")
  end

  test "persists failure state when called with a stale invocation struct" do
    assert {:ok, stale, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/stale-failure", "bafy-stale"),
               @received_at,
               nil
             )

    assert {:ok, current} =
             Store.transition(
               stale,
               :deferred_capacity,
               :capturing_thread,
               %{eligibility_method: "operator_allowlist"},
               nil
             )

    assert current.stage == :capturing_thread

    assert {:ok, failed} =
             Store.fail(stale, :thread_unavailable, %{reason: "invocation disappeared"})

    assert failed.status == :failed
    assert failed.stage == :failed
    assert failed.failure_category == :thread_unavailable
    assert failed.failure_detail == %{reason: "invocation disappeared"}

    persisted = Repo.reload!(stale)
    assert persisted.status == :failed
    assert persisted.failure_category == :thread_unavailable
  end

  test "failure categories are finite and unknown values are safely classified" do
    categories = [
      :invalid_input,
      :identity_unavailable,
      :rate_limited,
      :thread_unavailable,
      :provider_auth,
      :provider_budget,
      :provider_response,
      :publication_auth,
      :publication_conflict
    ]

    assert Enum.map(categories, &Failure.category/1) == categories
    assert Failure.category(:access_token) == :invalid_input
    assert Failure.category("Bearer secret") == :invalid_input
  end

  test "retains a complete maximum-size raw provider response byte-for-byte" do
    settings = Application.fetch_env!(:context_bot, :settings)
    raw_body = String.duplicate("x", settings.max_response_bytes)
    response = %{status: 200, raw_body: raw_body, parsed: %{"content" => ["projection"]}}

    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/large", "bafy-large"),
               @received_at,
               nil
             )

    assert {:ok, _updated} =
             Store.append_anthropic_response(invocation, response, settings.max_storage_bytes)

    [persisted_response] = Store.anthropic_responses(invocation)
    assert persisted_response.raw_body == raw_body
    assert byte_size(persisted_response.raw_body) == settings.max_response_bytes
    assert persisted_response.parsed == %{"content" => ["projection"]}
  end

  test "rejects only when the complete cumulative provider ledger exceeds its larger cap" do
    raw_body = String.duplicate("y", 70)
    response = %{status: 200, raw_body: raw_body}
    storage_cap = 120

    assert storage_cap > byte_size(raw_body)

    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/ledger", "bafy-ledger"),
               @received_at,
               nil
             )

    assert {:ok, with_one_response} =
             Store.append_anthropic_response(invocation, response, storage_cap)

    assert {:error, :provider_storage_limit} =
             Store.append_anthropic_response(with_one_response, response, storage_cap)

    [persisted_response] = Store.anthropic_responses(invocation)
    assert persisted_response.raw_body == raw_body
  end

  test "reports actual legacy and BLOB envelope storage occupancy" do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/occupancy", "bafy-occupancy"),
               @received_at,
               nil
             )

    legacy_responses = [%{"raw_body" => String.duplicate("l", 37), "status" => 503}]

    invocation
    |> Invocation.anthropic_responses_changeset(legacy_responses)
    |> Repo.update!()

    assert {:ok, _invocation} =
             Store.append_anthropic_response(
               invocation,
               response_envelope("persisted-envelope"),
               1_000_000
             )

    %{rows: [[legacy_bytes]]} =
      SQL.query!(
        Repo,
        "SELECT COALESCE(length(anthropic_responses), 0) FROM invocations WHERE id = ?",
        [invocation.id]
      )

    envelope_bytes =
      ResponseEnvelope
      |> Query.where([response], response.invocation_id == ^invocation.id)
      |> Repo.aggregate(:sum, :storage_bytes)

    assert Store.provider_response_storage_bytes(invocation) == legacy_bytes + envelope_bytes
  end

  test "atomically stores arbitrary response bytes in an ordered BLOB ledger with the marker" do
    invocation = researching_invocation("blob-ledger")
    raw_body = <<0, 255, 128, 65, 0, 254>>

    response = %{
      status: 503,
      headers: %{"content-type" => ["text/html"], "retry-after" => ["7"]},
      raw_body: raw_body,
      received_at: @received_at,
      duration_ms: 19
    }

    assert {:ok, reserved} =
             Budget.reserve_next(
               invocation,
               :research,
               @received_at,
               100,
               1_000,
               "blob-owner"
             )

    assert {:ok, sent} = Budget.mark_sent(reserved, @received_at, "blob-owner")

    assert {:ok, stored, recorded} =
             Store.record_anthropic_response(
               invocation,
               sent,
               response,
               1_000,
               @received_at,
               "blob-owner"
             )

    assert stored.raw_body == raw_body
    assert stored.attempt_key == sent.attempt_key
    assert stored.kind == :research
    assert stored.status == 503
    assert stored.headers == response.headers
    assert recorded.response_recorded_at == @received_at
    assert Repo.reload!(invocation).anthropic_responses == []

    assert [ledger_response] = Store.anthropic_responses(invocation)
    assert ledger_response.raw_body == raw_body
  end

  test "cumulative BLOB-ledger cap and response marker remain atomic" do
    invocation = researching_invocation("blob-cap")

    assert {:ok, first_entry} =
             Budget.reserve_next(
               invocation,
               :research,
               @received_at,
               100,
               1_000,
               "blob-owner"
             )

    assert {:ok, first_entry} =
             Budget.mark_sent(first_entry, @received_at, "blob-owner")

    assert {:ok, first, _recorded} =
             Store.record_anthropic_response(
               invocation,
               first_entry,
               response_envelope("first"),
               1_000,
               @received_at,
               "blob-owner"
             )

    assert {:ok, second_entry} =
             Budget.reserve_next(
               invocation,
               :retry,
               @received_at,
               100,
               1_000,
               "blob-owner"
             )

    assert {:ok, second_entry} =
             Budget.mark_sent(second_entry, @received_at, "blob-owner")

    assert {:error, :provider_storage_limit} =
             Store.record_anthropic_response(
               invocation,
               second_entry,
               response_envelope("second"),
               first.storage_bytes + byte_size("second"),
               @received_at,
               "blob-owner"
             )

    assert [%{attempt_key: attempt_key}] = Store.anthropic_responses(invocation)
    assert attempt_key == first_entry.attempt_key
    assert Repo.reload!(second_entry).response_recorded_at == nil
    assert length(Store.anthropic_responses(invocation)) == 1
  end

  defp mention(uri, cid) do
    %{
      uri: uri,
      cid: cid,
      actor_did: "did:plc:actor",
      actor_handle: "actor.example",
      raw: %{
        "uri" => uri,
        "cid" => cid,
        "author" => %{"did" => "did:plc:actor", "handle" => "actor.example"}
      }
    }
  end

  defp thread_job(uri, cid) do
    Oban.Job.new(
      %{"uri" => uri, "cid" => cid},
      worker: "ContextBot.Workers.ThreadWorker",
      queue: :thread
    )
  end

  defp dry_invocation!(target_uri, question, received_at, stage, options \\ []) do
    run_id = Ecto.UUID.generate()
    dry_run = Keyword.get(options, :dry_run, true)

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: dry_run,
      target_uri: target_uri,
      invocation_text: question,
      invocation_uri: "local://context-bot/fixtures/#{run_id}",
      notification_cid: "fixture:#{run_id}",
      current_cid: "fixture:#{run_id}",
      actor_did: "local:operator",
      raw_notification: %{"source" => "fixture"},
      received_at: received_at,
      status: stage,
      stage: stage
    })
    |> Repo.insert!()
  end

  defp researching_invocation(suffix) do
    assert {:ok, invocation, :inserted} =
             Store.receive_mention(
               mention("at://did:plc:actor/app.bsky.feed.post/#{suffix}", "bafy-#{suffix}"),
               @received_at,
               nil
             )

    assert {:ok, ready} =
             Store.transition(invocation, :deferred_capacity, :thread_ready, %{}, nil)

    assert {:ok, claimed} =
             Store.claim_research(ready, "blob-owner", @received_at, @received_at)

    claimed
  end

  defp response_envelope(body) do
    %{
      status: 200,
      headers: %{"content-type" => ["application/json"]},
      raw_body: body,
      received_at: @received_at,
      duration_ms: 1
    }
  end
end
