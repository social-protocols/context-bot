defmodule ContextBot.LiveRunTest.InvocationPost do
  @moduledoc false

  def fetch(uri, settings, options) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:fetch, uri, settings, options})
    config[:fetch_result]
  end
end

defmodule ContextBot.LiveRunTest.Resolver do
  @moduledoc false

  def resolve_handle(handle) do
    config = Application.fetch_env!(:context_bot, __MODULE__)
    send(config[:test_pid], {:resolve_handle, handle})
    config[:result]
  end
end

defmodule ContextBot.LiveRunTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.LiveRun
  alias ContextBot.LiveRunTest.InvocationPost
  alias ContextBot.LiveRunTest.Resolver
  alias ContextBot.Settings
  alias ContextBot.Workflow.Invocation

  @invocation_uri "at://did:plc:actor/app.bsky.feed.post/3invoke"
  @reply_uri "at://did:plc:contextbot/app.bsky.feed.post/3reply"
  @now ~U[2026-08-12 00:00:00.000000Z]

  setup do
    original = Application.get_env(:context_bot, InvocationPost, :missing)
    original_resolver = Application.get_env(:context_bot, Resolver, :missing)

    on_exit(fn ->
      restore_env(InvocationPost, original)
      restore_env(Resolver, original_resolver)
    end)

    :ok
  end

  test "resolves and prepares one validated public invocation idempotently" do
    receipt = receipt()
    configure_invocation_post({:ok, receipt})

    Application.put_env(:context_bot, Resolver,
      test_pid: self(),
      result: {:ok, 200, %{}, %{"did" => "did:plc:actor"}}
    )

    assert {:ok, @invocation_uri} =
             LiveRun.resolve("https://bsky.app/profile/actor.test/post/3invoke", Resolver)

    options = [invocation_post: InvocationPost, settings: settings(), now: fn -> @now end]
    assert {:ok, invocation, :created} = LiveRun.prepare(@invocation_uri, options)
    assert {:ok, attached, :attached} = LiveRun.prepare(@invocation_uri, options)
    assert attached.id == invocation.id

    assert_received {:resolve_handle, "actor.test"}
    assert_received {:fetch, @invocation_uri, %Settings{}, ^options}
    assert invocation.dry_run == false
    assert invocation.eligibility_method == "operator_live_demo"
    assert invocation.invocation_text == "What is missing?"
    assert invocation.stage == :capturing_thread

    assert [%Oban.Job{queue: "thread", worker: "ContextBot.Workers.ThreadWorker"}] =
             Repo.all(Oban.Job)
  end

  test "prepare propagates validation and active-invocation failures" do
    configure_invocation_post({:error, :missing_mention_facet})

    assert {:error, :missing_mention_facet} =
             LiveRun.prepare(@invocation_uri,
               invocation_post: InvocationPost,
               settings: settings()
             )

    active = insert_live_invocation!(:researching, invocation_uri: invocation_uri("other"))
    configure_invocation_post({:ok, receipt()})

    assert {:error, :active_invocation, %{id: id, uri: uri}} =
             LiveRun.prepare(@invocation_uri,
               invocation_post: InvocationPost,
               settings: settings()
             )

    assert id == active.id
    assert uri == active.invocation_uri
  end

  test "find returns one same-URI row, nil, or a contradiction" do
    assert LiveRun.find(@invocation_uri) == nil
    first = insert_live_invocation!(:failed, notification_cid: "bafy-one")
    assert LiveRun.find(@invocation_uri).id == first.id

    second = insert_live_invocation!(:failed, notification_cid: "bafy-two")

    assert {:error, :contradictory_invocations, ids} = LiveRun.find(@invocation_uri)
    assert ids == [first.id, second.id]
  end

  test "await reports completion, failure, ineligibility, and budget deferral" do
    for {stage, expected} <- [
          {:complete, :ok},
          {:failed, :error},
          {:ineligible, :error},
          {:deferred_budget, :deferred}
        ] do
      attrs =
        if stage == :complete,
          do: [invocation_uri: invocation_uri(stage), reply_uri: @reply_uri],
          else: [invocation_uri: invocation_uri(stage)]

      invocation = insert_live_invocation!(stage, attrs)
      assert {^expected, settled} = LiveRun.await(invocation, timeout_ms: 0)
      assert settled.id == invocation.id
    end
  end

  test "await times out, interrupts, rejects dry runs, and handles missing rows" do
    invocation = insert_live_invocation!(:capturing_thread)
    assert {:error, :timeout} = LiveRun.await(invocation, timeout_ms: 0)

    assert {:error, :interrupted} =
             LiveRun.await(invocation,
               timeout_ms: 1_000,
               interrupt?: fn -> true end
             )

    assert {:error, :not_found} =
             LiveRun.await(%{invocation | id: invocation.id + 1000}, timeout_ms: 0)

    assert {:error, :invalid_input} = LiveRun.await(%{invocation | dry_run: true})
    assert {:error, :invalid_input} = LiveRun.await(invocation, interrupt?: :invalid)
  end

  test "await invokes the callback only when durable stage changes" do
    invocation = insert_live_invocation!(:capturing_thread)

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

    assert {:ok, _settled} =
             LiveRun.await(invocation,
               timeout_ms: 1_000,
               poll_interval_ms: 1,
               sleep: sleep,
               on_update: fn current -> send(owner, {:stage, current.stage}) end
             )

    for stage <- [:capturing_thread, :thread_ready, :researching, :complete] do
      assert_receive {:stage, ^stage}
    end

    refute_receive {:stage, _duplicate}
  end

  test "reply_url renders only a parsed reply rkey with the configured handle" do
    complete = insert_live_invocation!(:complete, reply_uri: @reply_uri)

    assert LiveRun.reply_url(complete, "getcontext.bot") ==
             {:ok, "https://bsky.app/profile/getcontext.bot/post/3reply"}

    assert {:error, :invalid_reply_uri} =
             LiveRun.reply_url(
               %{complete | reply_uri: "https://evil.example/reply"},
               "getcontext.bot"
             )

    assert {:error, :invalid_reply_uri} =
             LiveRun.reply_url(%{complete | reply_uri: nil}, "getcontext.bot")

    assert {:error, :invalid_handle} = LiveRun.reply_url(complete, "  ")

    assert {:error, :invalid_input} =
             LiveRun.reply_url(%{complete | stage: :publishing}, "getcontext.bot")
  end

  defp receipt do
    %{
      uri: @invocation_uri,
      cid: "bafy-invocation",
      actor_did: "did:plc:actor",
      actor_handle: "actor.test",
      invocation_text: "What is missing?",
      raw: %{"source" => "local_live_demo", "post" => %{"uri" => @invocation_uri}}
    }
  end

  defp settings do
    Settings.load(
      bot_did: "did:plc:contextbot",
      bot_handle: "getcontext.bot",
      bot_pds_url: "https://pds.example",
      anthropic_daily_budget_usd: "20.000000"
    )
  end

  defp configure_invocation_post(fetch_result) do
    Application.put_env(:context_bot, InvocationPost,
      test_pid: self(),
      fetch_result: fetch_result
    )
  end

  defp insert_live_invocation!(stage, attrs \\ []) do
    base = %{
      dry_run: false,
      invocation_uri: @invocation_uri,
      notification_cid: "bafy-invocation",
      current_cid: "bafy-invocation",
      actor_did: "did:plc:actor",
      raw_notification: %{"source" => "local_live_demo"},
      received_at: @now,
      status: stage,
      stage: stage
    }

    %Invocation{}
    |> Invocation.changeset(Map.merge(base, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp invocation_uri(suffix),
    do: "at://did:plc:actor/app.bsky.feed.post/#{suffix}"

  defp restore_env(module, :missing), do: Application.delete_env(:context_bot, module)
  defp restore_env(module, value), do: Application.put_env(:context_bot, module, value)
end
