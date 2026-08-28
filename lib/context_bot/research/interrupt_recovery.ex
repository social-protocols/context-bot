defmodule ContextBot.Research.InterruptRecovery do
  @moduledoc """
  Classifies sent Anthropic attempts after a crash or deploy drain.

  The Messages API does not document request idempotency. While the HTTP timeout
  window is still open, recovery waits instead of starting a second paid call.
  After the window, the original attempt is treated as lost and a new reservation
  may be created. That can double-charge if Anthropic later completed the first
  call; a clean drain should make that rare.

  Automatic recover_failed reopens interruptions and locally retryable envelope
  work. It does not reopen deterministic parser hard-fails; those stay failed
  until an operator reprocess. `code_execution_failed` reprocess starts a new
  paid attempt instead of replaying the failed envelope.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{Budget, BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workflow.Invocation

  @type action :: :wait_for_timeout | :new_attempt | :replay_envelope

  # Local parser outcomes that cannot change on replay of the same retained envelope.
  # Automatic recover_failed must not reopen these; operator reprocess may.
  @parse_hard_fail_reasons MapSet.new([
                             "code_execution_failed",
                             "empty_reply",
                             "invalid_content",
                             "invalid_repair",
                             "malformed_provider_response",
                             "max_tokens",
                             "model_context_window_exceeded",
                             "pause_turn",
                             "pending_tool_use",
                             "refusal",
                             "tool_use",
                             "unexpected_content_block",
                             "unexpected_stop_reason",
                             "unexpected_tool_use"
                           ])

  @spec remaining_ms(BudgetEntry.t() | nil, DateTime.t(), pos_integer()) :: non_neg_integer()
  def remaining_ms(%BudgetEntry{sent_at: %DateTime{} = sent_at}, %DateTime{} = now, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    elapsed = DateTime.diff(now, sent_at, :millisecond)
    max(timeout_ms - elapsed, 0)
  end

  def remaining_ms(_entry, _now, _timeout_ms), do: 0

  @spec in_flight_attempt(Invocation.t(), DateTime.t(), pos_integer()) ::
          {BudgetEntry.t(), pos_integer()} | nil
  def in_flight_attempt(%Invocation{} = invocation, %DateTime{} = now, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    invocation
    |> Budget.unrecorded_exposed_attempts()
    |> Enum.reduce(nil, fn entry, acc ->
      keep_longest_wait(entry, acc, remaining_ms(entry, now, timeout_ms))
    end)
  end

  @spec interrupted_after_send?(Invocation.t()) :: boolean()
  def interrupted_after_send?(%Invocation{
        failure_category: :provider_response,
        failure_detail: detail
      })
      when is_map(detail),
      do: detail["reason"] == "interrupted_after_send"

  def interrupted_after_send?(_invocation), do: false

  @spec published?(Invocation.t()) :: boolean()
  def published?(%Invocation{reply_uri: uri}) when is_binary(uri) and uri != "", do: true
  def published?(_invocation), do: false

  @spec can_restart_research?(Invocation.t()) :: boolean()
  def can_restart_research?(%Invocation{
        canonical_thread: thread,
        anthropic_messages: messages
      })
      when is_binary(thread) and thread != "" and is_map(messages),
      do: true

  def can_restart_research?(_invocation), do: false

  @spec deterministic_parse_hard_fail?(Invocation.t()) :: boolean()
  def deterministic_parse_hard_fail?(%Invocation{
        failure_category: :provider_response,
        failure_detail: %{"reason" => reason}
      })
      when is_binary(reason),
      do: MapSet.member?(@parse_hard_fail_reasons, reason)

  def deterministic_parse_hard_fail?(_invocation), do: false

  @spec code_execution_failed?(Invocation.t()) :: boolean()
  def code_execution_failed?(%Invocation{
        failure_category: :provider_response,
        failure_detail: %{"reason" => "code_execution_failed"}
      }),
      do: true

  def code_execution_failed?(_invocation), do: false

  @spec replayable_recorded_response?(Invocation.t()) :: boolean()
  def replayable_recorded_response?(%Invocation{id: invocation_id}) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation_id)
    |> order_by([entry], desc: entry.id)
    |> limit(1)
    |> Repo.one()
    |> replayable_entry?()
  end

  defp replayable_entry?(%BudgetEntry{id: entry_id, response_recorded_at: %DateTime{}}) do
    case Repo.get_by(ResponseEnvelope, budget_entry_id: entry_id) do
      %ResponseEnvelope{status: status, raw_body: raw_body}
      when status in 200..299 and is_binary(raw_body) ->
        match?({:ok, decoded} when is_map(decoded), Jason.decode(raw_body))

      _missing_or_invalid ->
        false
    end
  end

  defp replayable_entry?(_entry), do: false

  defp keep_longest_wait(_entry, acc, 0), do: acc

  defp keep_longest_wait(entry, nil, remaining), do: {entry, remaining}

  defp keep_longest_wait(entry, {_current, current_remaining}, remaining)
       when remaining > current_remaining,
       do: {entry, remaining}

  defp keep_longest_wait(_entry, acc, _remaining), do: acc
end
