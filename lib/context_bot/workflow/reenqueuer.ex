defmodule ContextBot.Workflow.Reenqueuer do
  @moduledoc """
  Resets one failed or unpublished-complete invocation in place and enqueues a
  fresh two-phase research run.

  This is an explicit operator action, not envelope replay and not ordinary
  orphan recovery. It never deletes the invocation row, never resets budget
  spend history, never starts a second Bluesky TID after any published reply
  part, and never reopens an unrecorded provider attempt that is still inside
  the HTTP timeout window. `Reprocessor.reprocess/2` remains the path that
  replays a retained 2xx envelope.
  """

  alias ContextBot.Repo
  alias ContextBot.Research.InterruptRecovery
  alias ContextBot.Workers.ResearchWorker
  alias ContextBot.Workflow.Invocation

  @type error_reason ::
          :not_found
          | :not_reenqueueable
          | :already_published
          | :ambiguous_provider_attempt

  @spec reenqueue(pos_integer(), keyword()) ::
          {:ok, Invocation.t()} | {:error, error_reason()}
  def reenqueue(invocation_id, options \\ [])
      when is_integer(invocation_id) and invocation_id > 0 and is_list(options) do
    now = Keyword.get(options, :now, DateTime.utc_now())

    result =
      Repo.transaction(
        fn -> reset(invocation_id, now) end,
        mode: :immediate
      )

    case result do
      {:ok, %Invocation{} = invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset(invocation_id, %DateTime{} = now) do
    invocation = Repo.get(Invocation, invocation_id) || Repo.rollback(:not_found)
    reject_published!(invocation)
    validate_invocation!(invocation)
    reject_in_flight!(invocation, now)
    enqueue_reset(invocation, now)
  end

  defp reject_published!(invocation) do
    if already_published?(invocation) do
      Repo.rollback(:already_published)
    else
      :ok
    end
  end

  defp already_published?(%Invocation{} = invocation) do
    published_uri?(invocation.reply_uri) or
      published_uri?(invocation.reply_part2_uri) or
      published_uri?(invocation.reply_part3_uri)
  end

  defp published_uri?(uri) when is_binary(uri) and uri != "", do: true
  defp published_uri?(_uri), do: false

  defp reject_in_flight!(invocation, now) do
    timeout_ms = Application.fetch_env!(:context_bot, :settings).anthropic_http_timeout_ms

    case InterruptRecovery.in_flight_attempt(invocation, now, timeout_ms) do
      nil -> :ok
      _in_flight -> Repo.rollback(:ambiguous_provider_attempt)
    end
  end

  defp validate_invocation!(invocation) do
    if reenqueueable?(invocation) do
      :ok
    else
      Repo.rollback(:not_reenqueueable)
    end
  end

  defp reenqueueable?(%Invocation{status: status, stage: stage} = invocation)
       when status in [:failed, :complete] and stage == status do
    present_thread?(invocation) and not dry_run_broken?(invocation)
  end

  defp reenqueueable?(_invocation), do: false

  defp present_thread?(%Invocation{canonical_thread: thread})
       when is_binary(thread) and thread != "",
       do: true

  defp present_thread?(_invocation), do: false

  # A dry-run row missing its required identity inputs cannot rebuild Request.initial.
  defp dry_run_broken?(%Invocation{dry_run: true} = invocation) do
    blank?(invocation.target_uri) or blank?(invocation.invocation_text)
  end

  defp dry_run_broken?(_invocation), do: false

  defp blank?(value) when is_binary(value) and value != "", do: false
  defp blank?(_value), do: true

  defp enqueue_reset(invocation, now) do
    reopened =
      invocation
      |> Invocation.transition_changeset(reset_attrs(now))
      |> Repo.update!()

    reopened
    |> research_job()
    |> Repo.insert!()

    reopened
  end

  defp reset_attrs(%DateTime{} = now) do
    %{
      status: :thread_ready,
      stage: :thread_ready,
      anthropic_messages: nil,
      anthropic_usage: nil,
      citation_sources: [],
      full_response: nil,
      selected_reply: nil,
      reply_validation: nil,
      no_reply: false,
      standard_site_document_uri: nil,
      standard_site_document_rkey: nil,
      reader_ready_at: nil,
      reader_checked_at: nil,
      reply_repo: nil,
      reply_rkey: nil,
      reply_record: nil,
      reply_part2_rkey: nil,
      reply_part2_record: nil,
      reply_part3_rkey: nil,
      reply_part3_record: nil,
      reply_uri: nil,
      reply_cid: nil,
      reply_part2_uri: nil,
      reply_part2_cid: nil,
      reply_part3_uri: nil,
      reply_part3_cid: nil,
      publication_claim_token: nil,
      publication_claimed_at: nil,
      research_claim_token: nil,
      research_claimed_at: nil,
      failure_category: nil,
      failure_detail: nil,
      completed_at: nil,
      defer_until: nil,
      deferred_attempt_kind: nil,
      recovery_checked_at: now
    }
  end

  defp research_job(%Invocation{} = invocation) do
    queue = if invocation.dry_run, do: :dry_research, else: :research

    args = %{
      "uri" => invocation.invocation_uri,
      "cid" => invocation.notification_cid,
      "reenqueue_token" => Ecto.UUID.generate(),
      "new_attempt" => true
    }

    ResearchWorker.new(args, queue: queue)
  end
end
