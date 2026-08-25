defmodule ContextBot.Workers.ResearchWorker do
  @moduledoc """
  Claims durable thread snapshots, runs bounded research, and freezes publication intent.

  The exact reply record and all research evidence are committed in the same transaction that
  makes a future reply job visible. The runner performs every external call outside transactions.
  """

  use Oban.Worker, queue: :research, max_attempts: 5

  import Ecto.Query

  alias ContextBot.ATProto.TID
  alias ContextBot.{Operations, Repo}
  alias ContextBot.Reply.Intent
  alias ContextBot.Research.Runner
  alias ContextBot.Workflow.{Invocation, Store}

  @reply_worker "ContextBot.Workers.ReplyWorker"
  @default_claim_lease_ms 21_600_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}} = job)
      when is_binary(uri) and is_binary(cid) do
    dependencies = dependencies()

    case find_invocation(uri, cid) do
      nil -> :ok
      invocation -> process(invocation, job, dependencies)
    end
  end

  def perform(%Oban.Job{}), do: :ok

  defp find_invocation(uri, cid) do
    Invocation
    |> where(
      [invocation],
      invocation.invocation_uri == ^uri and invocation.notification_cid == ^cid
    )
    |> Repo.one()
  end

  defp process(invocation, job, dependencies) do
    now = dependencies.now.()
    token = claim_token(job)
    stale_before = DateTime.add(now, -dependencies.claim_lease_ms, :millisecond)

    case Store.claim_research(invocation, token, now, stale_before) do
      {:ok, claimed} ->
        logged_run(claimed, job, token, dependencies)

      {:error, reason} when reason in [:busy, :stale_stage] ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp logged_run(invocation, job, token, dependencies) do
    started_at = System.monotonic_time(:millisecond)
    result = run(invocation, token, dependencies)

    Operations.log_attempt(invocation,
      attempt_kind: :research,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: research_failure(invocation)
    )

    result
  end

  defp run(invocation, token, dependencies) do
    options =
      dependencies.runner_options
      |> put_runner_setting(dependencies.settings)
      |> put_runner_claim(token)

    case dependencies.runner.run(invocation, options) do
      {:ok, result} ->
        freeze_handoff(Repo.reload!(invocation), result, token, dependencies)

      {:deferred, %DateTime{} = defer_until, kind} ->
        defer_budget(invocation, defer_until, kind, token)

      {:deferred, %DateTime{} = defer_until} ->
        defer_budget(invocation, defer_until, :research, token)

      {:error, :stale_claim} ->
        :ok

      {:error, reason} ->
        fail_research(invocation, reason, dependencies.now.(), token)
    end
  end

  defp freeze_handoff(%Invocation{dry_run: true} = invocation, result, token, dependencies) do
    completed_at = dependencies.now.()

    attrs = %{
      anthropic_messages: result.messages,
      anthropic_usage: result.usage,
      selected_reply: result.text,
      reply_validation: result.validation,
      reply_repo: nil,
      reply_rkey: nil,
      reply_record: nil,
      publication_claim_token: nil,
      publication_claimed_at: nil,
      defer_until: nil,
      failure_category: nil,
      failure_detail: nil,
      research_claim_token: nil,
      research_claimed_at: nil,
      completed_at: completed_at,
      deferred_attempt_kind: nil
    }

    case Store.transition_research(invocation, token, :complete, attrs, nil, completed_at) do
      {:ok, _complete} ->
        :ok

      {:error, :stale_claim} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp freeze_handoff(invocation, result, token, dependencies) do
    created_at = dependencies.now.()

    intent_result =
      if Map.has_key?(result, :text_part2) do
        Intent.build_with_part2(
          invocation,
          result.text,
          result.text_part2,
          dependencies.settings.bot_did,
          created_at,
          dependencies.tid_generator
        )
      else
        dependencies.intent_builder.(
          invocation,
          result.text,
          dependencies.settings.bot_did,
          created_at,
          dependencies.tid_generator
        )
      end

    case intent_result do
      {:ok, intent} ->
        attrs = %{
          anthropic_messages: result.messages,
          anthropic_usage: result.usage,
          selected_reply: result.text,
          reply_validation: result.validation,
          reply_repo: intent.reply_repo,
          reply_rkey: intent.reply_rkey,
          reply_record: intent.reply_record,
          reply_part2_rkey: Map.get(intent, :reply_part2_rkey),
          reply_part2_record: Map.get(intent, :reply_part2_record),
          publication_claim_token: nil,
          publication_claimed_at: nil,
          defer_until: nil,
          failure_category: nil,
          failure_detail: nil,
          research_claim_token: nil,
          research_claimed_at: nil,
          completed_at: nil,
          deferred_attempt_kind: nil
        }

        next_job = dependencies.reply_job_builder.(invocation)

        case Store.transition_research(
               invocation,
               token,
               :reply_ready,
               attrs,
               next_job,
               created_at
             ) do
          {:ok, _reply_ready} ->
            :ok

          {:error, :stale_claim} ->
            :ok

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
        end

      {:error, reason} ->
        fail_research(invocation, reason, created_at, token)
    end
  end
  defp defer_budget(invocation, defer_until, kind, token) do
    case Store.transition_research(
           Repo.reload!(invocation),
           token,
           :deferred_budget,
           %{
             defer_until: defer_until,
             deferred_attempt_kind: kind,
             research_claim_token: nil,
             research_claimed_at: nil
           },
           nil,
           defer_until
         ) do
      {:ok, _deferred} ->
        :ok

      {:error, :stale_claim} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp fail_research(invocation, reason, completed_at, token) do
    reason_string = safe_reason(reason)

    case Store.transition_research(
           Repo.reload!(invocation),
           token,
           :failed,
           %{
             failure_category: failure_category(reason),
             failure_detail: %{"reason" => reason_string},
             research_claim_token: nil,
             research_claimed_at: nil,
             completed_at: completed_at
           },
           nil,
           completed_at
         ) do
      {:ok, _failed} ->
        :ok

      {:error, :stale_claim} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp failure_category(:provider_auth), do: :provider_auth
  defp failure_category(:daily_budget_exhausted), do: :provider_budget
  defp failure_category(_reason), do: :provider_response

  defp research_failure(invocation) do
    case Repo.reload!(invocation) do
      %Invocation{stage: :failed, failure_category: category} -> category
      _nonterminal_or_complete -> nil
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "provider_failure"

  defp claim_token(%Oban.Job{id: id}) when is_integer(id), do: "research-job-#{id}"

  defp claim_token(%Oban.Job{}) do
    unique = System.unique_integer([:positive, :monotonic])
    "research-process-#{inspect(self())}-#{unique}"
  end

  defp put_runner_setting(options, settings) when is_list(options),
    do: Keyword.put(options, :settings, settings)

  defp put_runner_setting(options, settings) when is_map(options),
    do: Map.put(options, :settings, settings)

  defp put_runner_claim(options, token) when is_list(options),
    do: Keyword.put(options, :claim_token, token)

  defp put_runner_claim(options, token) when is_map(options),
    do: Map.put(options, :claim_token, token)

  defp reply_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @reply_worker,
      queue: :reply
    )
  end

  defp dependencies do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      claim_lease_ms: Keyword.get(config, :claim_lease_ms, @default_claim_lease_ms),
      intent_builder: Keyword.get(config, :intent_builder, &Intent.build/5),
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      reply_job_builder: Keyword.get(config, :reply_job_builder, &reply_job/1),
      runner: Keyword.get(config, :runner, Runner),
      runner_options: Keyword.get(config, :runner_options, []),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings)),
      tid_generator: Keyword.get(config, :tid_generator, &TID.generate/1)
    }
  end
end
