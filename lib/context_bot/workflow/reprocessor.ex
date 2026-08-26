defmodule ContextBot.Workflow.Reprocessor do
  @moduledoc """
  Reopens a local provider-processing failure only when its paid response is durably replayable.

  This is an explicit operator action, not ordinary orphan recovery. It never reopens ambiguous
  provider exposure and never performs provider or ATProto I/O itself.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{Budget, BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workers.ResearchWorker
  alias ContextBot.Workflow.Invocation

  @type error_reason ::
          :not_found
          | :not_reprocessable
          | :ambiguous_provider_attempt
          | :missing_recorded_response
          | :invalid_recorded_response

  @spec reprocess(pos_integer(), keyword()) ::
          {:ok, Invocation.t()} | {:error, error_reason()}
  def reprocess(invocation_id, options \\ [])
      when is_integer(invocation_id) and invocation_id > 0 and is_list(options) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    result =
      Repo.transaction(
        fn -> reopen(invocation_id, now) end,
        mode: :immediate
      )

    case result do
      {:ok, %Invocation{} = invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reopen(invocation_id, %DateTime{} = now) do
    invocation = Repo.get(Invocation, invocation_id) || Repo.rollback(:not_found)
    validate_invocation!(invocation)

    if Budget.unrecorded_exposed_attempt(invocation) do
      Repo.rollback(:ambiguous_provider_attempt)
    end

    entry = latest_attempt(invocation) || Repo.rollback(:missing_recorded_response)
    envelope = recorded_response(entry) || Repo.rollback(:missing_recorded_response)
    validate_response!(entry, envelope)

    reopened =
      invocation
      |> Invocation.transition_changeset(%{
        status: :thread_ready,
        stage: :thread_ready,
        defer_until: nil,
        deferred_attempt_kind: nil,
        recovery_checked_at: now,
        research_claim_token: nil,
        research_claimed_at: nil,
        selected_reply: nil,
        reply_validation: nil,
        reply_repo: nil,
        reply_rkey: nil,
        reply_record: nil,
        reply_part2_rkey: nil,
        reply_part2_record: nil,
        publication_claim_token: nil,
        publication_claimed_at: nil,
        reply_uri: nil,
        reply_cid: nil,
        reply_part2_uri: nil,
        reply_part2_cid: nil,
        failure_category: nil,
        failure_detail: nil,
        completed_at: nil
      })
      |> Repo.update!()

    reopened
    |> research_job()
    |> Repo.insert!()

    reopened
  end

  defp validate_invocation!(%Invocation{
         status: :failed,
         stage: :failed,
         failure_category: :provider_response,
         canonical_thread: canonical_thread,
         anthropic_messages: anthropic_messages
       })
       when is_binary(canonical_thread) and canonical_thread != "" and
              is_map(anthropic_messages),
       do: :ok

  defp validate_invocation!(%Invocation{
         status: :complete,
         stage: :complete,
         canonical_thread: canonical_thread,
         anthropic_messages: anthropic_messages
       })
       when is_binary(canonical_thread) and canonical_thread != "" and
              is_map(anthropic_messages),
       do: :ok

  defp validate_invocation!(%Invocation{}), do: Repo.rollback(:not_reprocessable)

  defp validate_response!(
         %BudgetEntry{response_recorded_at: %DateTime{}},
         %ResponseEnvelope{status: status, raw_body: raw_body}
       )
       when status in 200..299 and is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} when is_map(decoded) -> :ok
      _invalid -> Repo.rollback(:invalid_recorded_response)
    end
  end

  defp validate_response!(%BudgetEntry{}, %ResponseEnvelope{}),
    do: Repo.rollback(:invalid_recorded_response)

  defp latest_attempt(%Invocation{id: invocation_id}) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation_id)
    |> order_by([entry], desc: entry.id)
    |> limit(1)
    |> Repo.one()
  end

  defp recorded_response(%BudgetEntry{id: entry_id}) do
    Repo.get_by(ResponseEnvelope, budget_entry_id: entry_id)
  end

  defp research_job(%Invocation{} = invocation) do
    queue = if invocation.dry_run, do: :dry_research, else: :research

    %{
      "uri" => invocation.invocation_uri,
      "cid" => invocation.notification_cid,
      "reprocess_token" => Ecto.UUID.generate()
    }
    |> ResearchWorker.new(queue: queue)
  end
end
