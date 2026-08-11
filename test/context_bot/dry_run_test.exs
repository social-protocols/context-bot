defmodule ContextBot.DryRunTest.PostReference do
  @moduledoc false

  def normalize(reference, resolver) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:normalize, reference, resolver})
    config[:result]
  end
end

defmodule ContextBot.DryRunTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.DryRun
  alias ContextBot.DryRunTest.PostReference
  alias ContextBot.Workflow.Invocation

  @target_uri "at://did:plc:target/app.bsky.feed.post/selected"
  @now ~U[2026-08-09 12:00:00.000000Z]

  setup do
    original = Application.get_env(:context_bot, PostReference, :missing)
    on_exit(fn -> restore_env(PostReference, original) end)
    :ok
  end

  test "normalizes before creating or attaching durable thread work" do
    configure_reference({:ok, @target_uri})
    url = "https://bsky.app/profile/target.test/post/selected"

    options =
      [
        post_reference: PostReference,
        resolver: :public_resolver,
        now: fn -> @now end
      ]

    assert {:ok, invocation, :created} = DryRun.prepare(url, "Is this fair?", options)
    assert {:ok, same, :attached} = DryRun.prepare(url, "Is this fair?", options)
    assert same.id == invocation.id

    assert_received {:normalize, ^url, :public_resolver}
    assert_received {:normalize, ^url, :public_resolver}

    assert invocation.dry_run
    assert invocation.target_uri == @target_uri
    assert invocation.invocation_text == "Is this fair?"
    assert invocation.received_at == @now

    assert [%Oban.Job{worker: "ContextBot.Workers.ThreadWorker", queue: "dry_thread"}] =
             Repo.all(Oban.Job)

    assert [%Invocation{target_uri: @target_uri}] = Repo.all(Invocation)
  end

  test "invalid references and questions create no durable state" do
    configure_reference({:error, :invalid_post_reference})

    assert {:error, :invalid_post_reference} =
             DryRun.prepare("not-a-post", "Question",
               post_reference: PostReference,
               resolver: :public_resolver
             )

    assert_received {:normalize, "not-a-post", :public_resolver}

    assert Repo.aggregate(Invocation, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0

    configure_reference({:ok, @target_uri})

    assert {:error, :invalid_input} =
             DryRun.prepare(@target_uri, "   ",
               post_reference: PostReference,
               resolver: :public_resolver
             )

    refute_received {:normalize, @target_uri, :public_resolver}

    assert {:error, :invalid_input} =
             DryRun.prepare(@target_uri, String.duplicate("x", 10_001),
               post_reference: PostReference,
               resolver: :public_resolver
             )

    refute_received {:normalize, @target_uri, :public_resolver}

    assert Repo.aggregate(Invocation, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "await reloads only the selected row through complete, failure, and budget deferral" do
    for {terminal, expected} <- [
          {:complete, :ok},
          {:failed, :error},
          {:deferred_budget, :deferred}
        ] do
      invocation = invocation("await-#{terminal}")

      sleep = fn _milliseconds ->
        invocation
        |> Repo.reload!()
        |> Invocation.transition_changeset(%{
          status: terminal,
          stage: terminal,
          selected_reply: if(terminal == :complete, do: "Tested answer."),
          failure_category: if(terminal == :failed, do: :provider_response),
          defer_until: if(terminal == :deferred_budget, do: DateTime.add(@now, 60))
        })
        |> Repo.update!()
      end

      assert {^expected, settled} =
               DryRun.await(invocation, timeout_ms: 1_000, poll_interval_ms: 1, sleep: sleep)

      assert settled.id == invocation.id
      assert settled.stage == terminal
    end
  end

  test "await returns a finite timeout without changing the row" do
    invocation = invocation("timeout")
    assert {:error, :timeout} = DryRun.await(invocation, timeout_ms: 0)
    assert Repo.reload!(invocation).stage == :capturing_thread
  end

  test "await stops promptly on interruption without mutating durable workflow state" do
    invocation = invocation("interrupted")

    job =
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid}
      |> Oban.Job.new(worker: "ContextBot.Workers.ThreadWorker", queue: :dry_thread)
      |> Repo.insert!()

    Process.put(:interrupt_checks, 0)

    interrupt? = fn ->
      checks = Process.get(:interrupt_checks)
      Process.put(:interrupt_checks, checks + 1)
      checks > 0
    end

    assert {:error, :interrupted} =
             DryRun.await(invocation,
               timeout_ms: 1_000,
               poll_interval_ms: 1,
               sleep: fn _milliseconds -> :ok end,
               interrupt?: interrupt?
             )

    assert Repo.reload!(invocation).stage == :capturing_thread
    assert Repo.reload!(job).state == "available"
  end

  test "await rejects an invalid interrupt callback" do
    assert {:error, :invalid_input} =
             DryRun.await(invocation("invalid-interrupt"), interrupt?: true)
  end

  test "await reports the initial row and each persisted stage transition once" do
    invocation = invocation("stage-updates")

    sleep = fn _milliseconds ->
      current = Repo.reload!(invocation)

      next_stage =
        case current.stage do
          :capturing_thread -> :thread_ready
          :thread_ready -> :researching
          :researching -> :complete
        end

      current
      |> Invocation.transition_changeset(%{status: next_stage, stage: next_stage})
      |> Repo.update!()
    end

    owner = self()

    assert {:ok, settled} =
             DryRun.await(invocation,
               timeout_ms: 1_000,
               poll_interval_ms: 1,
               sleep: sleep,
               on_update: fn current -> send(owner, {:stage, current.stage}) end
             )

    assert settled.stage == :complete
    assert_receive {:stage, :capturing_thread}
    assert_receive {:stage, :thread_ready}
    assert_receive {:stage, :researching}
    assert_receive {:stage, :complete}
    refute_receive {:stage, _duplicate}
  end

  test "await does not repeat callbacks while the persisted stage is unchanged" do
    invocation = invocation("same-stage")
    Process.put(:monotonic_call, 0)

    monotonic_ms = fn ->
      value = Process.get(:monotonic_call)
      Process.put(:monotonic_call, value + 1)
      value
    end

    owner = self()

    assert {:error, :timeout} =
             DryRun.await(invocation,
               timeout_ms: 3,
               poll_interval_ms: 1,
               sleep: fn _milliseconds -> :ok end,
               monotonic_ms: monotonic_ms,
               on_update: fn current -> send(owner, {:stage, current.stage}) end
             )

    assert_receive {:stage, :capturing_thread}
    refute_receive {:stage, :capturing_thread}
  end

  defp invocation(suffix) do
    run_id = Ecto.UUID.generate()

    %Invocation{}
    |> Invocation.changeset(%{
      dry_run: true,
      target_uri: @target_uri,
      invocation_text: "What's missing?",
      invocation_uri: "local://context-bot/dry-runs/#{run_id}-#{suffix}",
      notification_cid: "local:#{run_id}-#{suffix}",
      current_cid: "local:#{run_id}-#{suffix}",
      actor_did: "local:operator",
      raw_notification: %{"source" => "local_dry_run"},
      received_at: @now,
      status: :capturing_thread,
      stage: :capturing_thread
    })
    |> Repo.insert!()
  end

  defp configure_reference(result) do
    Application.put_env(:context_bot, PostReference, test_pid: self(), result: result)
  end

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
