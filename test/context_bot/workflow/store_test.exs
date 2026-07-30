defmodule ContextBot.Workflow.StoreTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Workflow.{Failure, Invocation, Store}

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

    [persisted_response] = Repo.reload!(invocation).anthropic_responses
    assert persisted_response["raw_body"] == raw_body
    assert byte_size(persisted_response["raw_body"]) == settings.max_response_bytes
    assert persisted_response["parsed"] == %{"content" => ["projection"]}
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

    [persisted_response] = Repo.reload!(invocation).anthropic_responses
    assert persisted_response["raw_body"] == raw_body
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
end
