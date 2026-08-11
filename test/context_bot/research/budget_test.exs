defmodule ContextBot.Research.BudgetTest do
  use ContextBot.DataCase, async: false

  alias ContextBot.Research.{Budget, BudgetEntry, Pricing}
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-07-29 23:59:00.123456Z]

  test "allocates monotonic attempt keys in the same commit as invocation sequence" do
    invocation = invocation("monotonic")

    assert {:ok, first} = Budget.reserve_next(invocation, :research, @now, 300, 1_000)
    assert {:ok, second} = Budget.reserve_next(invocation, :continuation, @now, 300, 1_000)

    assert first.attempt_key == "invocation-#{invocation.id}-attempt-1-research"
    assert second.attempt_key == "invocation-#{invocation.id}-attempt-2-continuation"
    assert Repo.reload!(invocation).anthropic_attempt_sequence == 2
  end

  test "an exhausted reservation rolls back both the entry and sequence increment" do
    invocation = invocation("rollback")

    assert {:ok, _entry} = Budget.reserve_next(invocation, :research, @now, 700, 700)

    assert {:error, :daily_budget_exhausted} =
             Budget.reserve_next(invocation, :retry, @now, 1, 700)

    assert Repo.reload!(invocation).anthropic_attempt_sequence == 1
    assert Repo.aggregate(BudgetEntry, :count) == 1
  end

  test "settled entries count their settled cost instead of their reservation" do
    invocation = invocation("settled")
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:ok, entry} = Budget.reserve_next(invocation, :research, @now, 600, 1_000)
    assert {:ok, sent} = Budget.mark_sent(entry, @now)
    assert {:ok, recorded} = Budget.mark_response_recorded(sent, DateTime.add(@now, 1, :second))

    assert {:ok, settled} =
             Budget.settle(recorded, usage(output_tokens: 10), pricing)

    assert settled.state == :settled
    assert settled.settled_microdollars == 100
    assert settled.reserved_microdollars == 600
    assert settled.pricing_version == pricing.version
    assert Budget.remaining(@now, 1_000) == 900
    assert {:ok, _next} = Budget.reserve_next(invocation, :repair, @now, 900, 1_000)
  end

  test "reserved sent and indeterminate entries each count the full reservation" do
    invocation = invocation("full-exposure")

    assert {:ok, reserved} = Budget.reserve_next(invocation, :research, @now, 200, 1_000)
    assert Budget.remaining(@now, 1_000) == 800

    assert {:ok, sent} = Budget.mark_sent(reserved, @now)
    assert sent.state == :sent
    assert sent.sent_at == @now
    assert Budget.remaining(@now, 1_000) == 800

    assert {:ok, indeterminate} = Budget.mark_indeterminate(sent)
    assert indeterminate.state == :indeterminate
    assert Budget.remaining(@now, 1_000) == 800
  end

  test "unsafe or over-reservation usage retains the full reservation" do
    invocation = invocation("unsafe")
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:ok, unsafe} = Budget.reserve_next(invocation, :research, @now, 400, 1_000)
    assert {:ok, unsafe} = Budget.mark_sent(unsafe, @now)

    assert {:ok, unsafe} =
             Budget.mark_response_recorded(unsafe, DateTime.add(@now, 1, :second))

    assert {:ok, retained} = Budget.settle(unsafe, %{"output_tokens" => "unknown"}, pricing)
    assert retained.state == :indeterminate
    assert retained.settled_microdollars == nil

    assert {:ok, too_small} = Budget.reserve_next(invocation, :repair, @now, 50, 1_000)
    assert {:ok, too_small} = Budget.mark_sent(too_small, @now)

    assert {:ok, too_small} =
             Budget.mark_response_recorded(too_small, DateTime.add(@now, 1, :second))

    assert {:ok, retained} = Budget.settle(too_small, usage(output_tokens: 10), pricing)
    assert retained.state == :indeterminate
    assert retained.settled_microdollars == nil

    assert Budget.remaining(@now, 1_000) == 550
  end

  test "a recorded indeterminate attempt can settle after local usage validation is corrected" do
    invocation = invocation("recorded-indeterminate-resettlement")
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:ok, entry} = Budget.reserve_next(invocation, :repair, @now, 400, 1_000)
    assert {:ok, sent} = Budget.mark_sent(entry, @now)

    assert {:ok, recorded} =
             Budget.mark_response_recorded(sent, DateTime.add(@now, 1, :second))

    assert {:ok, indeterminate} =
             Budget.settle(recorded, %{"output_tokens" => "locally-unrecognized"}, pricing)

    assert indeterminate.state == :indeterminate
    assert indeterminate.response_recorded_at != nil

    assert {:ok, settled} = Budget.settle(indeterminate, usage(output_tokens: 10), pricing)
    assert settled.state == :settled
    assert settled.settled_microdollars == 100
    assert Budget.remaining(@now, 1_000) == 900
  end

  test "uses the UTC date for daily rollover" do
    invocation = invocation("rollover")
    next_day = ~U[2026-07-30 00:00:00.000000Z]

    assert {:ok, first} = Budget.reserve_next(invocation, :research, @now, 1_000, 1_000)
    assert first.budget_date == ~D[2026-07-29]

    assert {:error, :daily_budget_exhausted} =
             Budget.reserve_next(invocation, :retry, @now, 1, 1_000)

    assert {:ok, second} = Budget.reserve_next(invocation, :retry, next_day, 1_000, 1_000)
    assert second.budget_date == ~D[2026-07-30]
    assert second.attempt_key == "invocation-#{invocation.id}-attempt-2-retry"
  end

  test "recovery reuses unexposed reservations but retains exposed attempts" do
    invocation = invocation("recovery")

    assert {:ok, reserved} = Budget.reserve_next(invocation, :research, @now, 250, 1_000)
    assert {:reuse, ^reserved} = Budget.reconcile_attempt(reserved)
    assert Repo.reload!(invocation).anthropic_attempt_sequence == 1

    assert {:ok, sent} = Budget.mark_sent(reserved, @now)
    assert {:indeterminate, indeterminate} = Budget.reconcile_attempt(sent)
    assert indeterminate.state == :indeterminate
    assert Budget.remaining(@now, 1_000) == 750
  end

  test "recovery resumes a sent attempt whose response was durably recorded" do
    invocation = invocation("recorded")
    recorded_at = DateTime.add(@now, 1, :second)

    assert {:ok, entry} = Budget.reserve_next(invocation, :research, @now, 250, 1_000)
    assert {:ok, sent} = Budget.mark_sent(entry, @now)
    assert {:ok, recorded} = Budget.mark_response_recorded(sent, recorded_at)
    assert recorded.response_recorded_at == recorded_at
    assert {:resume, ^recorded} = Budget.reconcile_attempt(recorded)
  end

  test "does not mark a response-recorded sent attempt indeterminate" do
    invocation = invocation("recorded-indeterminate")
    recorded_at = DateTime.add(@now, 1, :second)

    assert {:ok, entry} = Budget.reserve_next(invocation, :research, @now, 250, 1_000)
    assert {:ok, sent} = Budget.mark_sent(entry, @now)
    assert {:ok, recorded} = Budget.mark_response_recorded(sent, recorded_at)
    assert {:ok, unchanged} = Budget.mark_indeterminate(recorded)
    assert unchanged.state == :sent
    assert unchanged.response_recorded_at == recorded_at
  end

  test "settlement never invents response durability or charges an unsent attempt" do
    invocation = invocation("state-order")
    pricing = Pricing.fetch!("sonnet-5-2026-07-28")

    assert {:ok, reserved} = Budget.reserve_next(invocation, :research, @now, 250, 1_000)
    assert {:ok, unchanged} = Budget.settle(reserved, usage(output_tokens: 1), pricing)
    assert unchanged.state == :reserved
    assert unchanged.response_recorded_at == nil
    assert unchanged.settled_microdollars == nil

    assert {:ok, unchanged} = Budget.mark_response_recorded(reserved, @now)
    assert unchanged.state == :reserved
    assert unchanged.response_recorded_at == nil

    assert {:ok, sent} = Budget.mark_sent(reserved, @now)
    assert {:ok, unchanged} = Budget.settle(sent, usage(output_tokens: 1), pricing)
    assert unchanged.state == :sent
    assert unchanged.response_recorded_at == nil
    assert unchanged.settled_microdollars == nil
  end

  defp invocation(suffix) do
    cid = "bafy-budget-#{suffix}"

    %Invocation{}
    |> Invocation.changeset(%{
      invocation_uri: "at://did:plc:actor/app.bsky.feed.post/#{suffix}",
      notification_cid: cid,
      current_cid: cid,
      actor_did: "did:plc:actor",
      raw_notification: %{"cid" => cid},
      received_at: @now,
      status: :deferred_budget,
      stage: :deferred_budget
    })
    |> Repo.insert!()
  end

  defp usage(overrides) do
    Map.merge(
      %{
        input_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_creation: %{
          ephemeral_5m_input_tokens: 0,
          ephemeral_1h_input_tokens: 0
        },
        cache_read_input_tokens: 0,
        output_tokens: 0,
        server_tool_use: %{web_search_requests: 0}
      },
      Map.new(overrides)
    )
  end
end

defmodule ContextBot.Research.BudgetConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{Budget, BudgetEntry}
  alias ContextBot.Workflow.Invocation
  alias Ecto.Adapters.SQL.Sandbox

  @now ~U[2026-07-29 12:00:00.000000Z]

  test "separate SQLite connections cannot jointly reserve beyond the daily limit" do
    invocation = committed_invocation()

    on_exit(fn -> delete_committed_invocation(invocation.id) end)

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Budget.reserve_next(invocation, :research, @now, 600, 1_000)
          after
            :ok = Sandbox.checkin(Repo)
          end
        end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, %BudgetEntry{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :daily_budget_exhausted})) == 1

    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      assert Budget.remaining(@now, 1_000) == 400
      assert Repo.reload!(invocation).anthropic_attempt_sequence == 1
    after
      :ok = Sandbox.checkin(Repo)
    end
  end

  defp committed_invocation do
    suffix = "concurrent-#{System.unique_integer([:positive])}"
    cid = "bafy-budget-#{suffix}"

    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      %Invocation{}
      |> Invocation.changeset(%{
        invocation_uri: "at://did:plc:actor/app.bsky.feed.post/#{suffix}",
        notification_cid: cid,
        current_cid: cid,
        actor_did: "did:plc:actor",
        raw_notification: %{"cid" => cid},
        received_at: @now,
        status: :deferred_budget,
        stage: :deferred_budget
      })
      |> Repo.insert!()
    after
      :ok = Sandbox.checkin(Repo)
    end
  end

  defp delete_committed_invocation(invocation_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      BudgetEntry
      |> where([entry], entry.invocation_id == ^invocation_id)
      |> Repo.delete_all()

      Invocation
      |> where([invocation], invocation.id == ^invocation_id)
      |> Repo.delete_all()
    after
      :ok = Sandbox.checkin(Repo)
    end
  end
end
