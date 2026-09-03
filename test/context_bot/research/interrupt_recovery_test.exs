defmodule ContextBot.Research.InterruptRecoveryTest do
  use ExUnit.Case, async: true

  alias ContextBot.Research.{BudgetEntry, InterruptRecovery}
  alias ContextBot.Workflow.Invocation

  @now ~U[2026-08-27 20:22:52.000000Z]

  test "counts remaining HTTP timeout from sent_at and treats a missing timestamp as elapsed" do
    entry = %BudgetEntry{sent_at: @now}
    timeout_ms = 300_000

    assert InterruptRecovery.remaining_ms(entry, @now, timeout_ms) == 300_000

    assert InterruptRecovery.remaining_ms(entry, DateTime.add(@now, 1, :second), timeout_ms) ==
             299_000

    assert InterruptRecovery.remaining_ms(
             entry,
             DateTime.add(@now, 300_000, :millisecond),
             timeout_ms
           ) == 0

    assert InterruptRecovery.remaining_ms(
             entry,
             DateTime.add(@now, 300_001, :millisecond),
             timeout_ms
           ) == 0

    assert InterruptRecovery.remaining_ms(%BudgetEntry{sent_at: nil}, @now, timeout_ms) == 0
  end

  test "identifies recoverable interrupt failures and published replies" do
    assert InterruptRecovery.interrupted_after_send?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "interrupted_after_send"}
           })

    refute InterruptRecovery.interrupted_after_send?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "unexpected_tool_use"}
           })

    assert InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "unexpected_tool_use"}
           })

    assert InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "code_execution_failed"}
           })

    assert InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "invalid_structured_output"}
           })

    assert InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :invalid_repair,
             failure_detail: %{"reason" => "invalid_repair"}
           })

    assert InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "invalid_repair"}
           })

    assert InterruptRecovery.code_execution_failed?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "code_execution_failed"}
           })

    refute InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "interrupted_after_send"}
           })

    refute InterruptRecovery.deterministic_parse_hard_fail?(%Invocation{
             failure_category: :provider_response,
             failure_detail: %{"reason" => "standard_site_document_failed"}
           })

    assert InterruptRecovery.published?(%Invocation{
             reply_uri: "at://did:plc:bot/app.bsky.feed.post/rkey"
           })

    refute InterruptRecovery.published?(%Invocation{reply_uri: nil})
  end
end
