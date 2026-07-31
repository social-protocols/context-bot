defmodule ContextBot.Workers.ResearchWorker do
  @moduledoc """
  Claims durable thread snapshots, runs bounded research, and freezes publication intent.

  The exact reply record and all research evidence are committed in the same transaction that
  makes a future reply job visible. The runner performs every external call outside transactions.
  """

  use Oban.Worker, queue: :research, max_attempts: 5

  import Ecto.Query

  alias ContextBot.ATProto.{Post, TID}
  alias ContextBot.Repo
  alias ContextBot.Research.Runner
  alias ContextBot.Workflow.{Invocation, Store}

  @reply_worker "ContextBot.Workers.ReplyWorker"
  @default_claim_lease_ms 21_600_000
  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

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
        run(claimed, token, dependencies)

      {:error, reason} when reason in [:busy, :stale_stage] ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp run(invocation, token, dependencies) do
    options =
      dependencies.runner_options
      |> put_runner_setting(dependencies.settings)
      |> put_runner_claim(token)

    case dependencies.runner.run(invocation, options) do
      {:ok, result} -> freeze_handoff(Repo.reload!(invocation), result, token, dependencies)
      {:deferred, %DateTime{} = defer_until} -> defer_budget(invocation, defer_until, token)
      {:error, :stale_claim} -> :ok
      {:error, reason} -> fail_research(invocation, reason, dependencies.now.(), token)
    end
  end

  defp freeze_handoff(invocation, result, token, dependencies) do
    created_at = dependencies.now.()
    rkey = dependencies.tid_generator.(DateTime.to_unix(created_at, :microsecond))

    parent = %{"uri" => invocation.invocation_uri, "cid" => invocation.current_cid}
    root = root_ref(invocation)

    with {:ok, reply_repo} <- publication_repo(dependencies.settings.bot_did),
         {:ok, record} <- Post.build(result.text, parent, root, created_at) do
      attrs = %{
        anthropic_messages: result.messages,
        anthropic_usage: result.usage,
        selected_reply: result.text,
        reply_validation: result.validation,
        reply_repo: reply_repo,
        reply_rkey: rkey,
        reply_record: record,
        publication_claim_token: nil,
        publication_claimed_at: nil,
        defer_until: nil,
        failure_category: nil,
        failure_detail: nil,
        research_claim_token: nil,
        research_claimed_at: nil,
        completed_at: nil
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
    else
      {:error, reason} ->
        fail_research(invocation, reason, created_at, token)
    end
  end

  defp publication_repo(repo) when is_binary(repo) and repo != "" do
    if Regex.match?(@did_regex, repo), do: {:ok, repo}, else: {:error, :invalid_publication_repo}
  end

  defp publication_repo(_repo), do: {:error, :invalid_publication_repo}

  defp root_ref(%Invocation{root_uri: root_uri, root_cid: root_cid})
       when is_binary(root_uri) and is_binary(root_cid),
       do: %{"uri" => root_uri, "cid" => root_cid}

  defp root_ref(_invocation), do: nil

  defp defer_budget(invocation, defer_until, token) do
    case Store.transition_research(
           Repo.reload!(invocation),
           token,
           :deferred_budget,
           %{
             defer_until: defer_until,
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
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      reply_job_builder: Keyword.get(config, :reply_job_builder, &reply_job/1),
      runner: Keyword.get(config, :runner, Runner),
      runner_options: Keyword.get(config, :runner_options, []),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings)),
      tid_generator: Keyword.get(config, :tid_generator, &TID.generate/1)
    }
  end
end
