defmodule ContextBot.Workers.ReplyWorker do
  @moduledoc """
  Reconciles one frozen Bluesky reply intent at its deterministic repository key.

  Publication is create-only. Every attempt reads before writing, and every possible write is
  accepted only after a subsequent read returns the exact persisted record and coordinates.

  Authorization failures stop in `failed/publication_auth` rather than retrying. After repairing
  credentials, an operator may deliberately resume the unchanged intent by resetting the stage to
  `reply_ready` and clearing the terminal markers while retaining `reply_rkey` and `reply_record`;
  the worker never performs that intervention automatically.
  """

  use Oban.Worker, queue: :reply, max_attempts: 10

  import Ecto.Query

  alias ContextBot.ATProto.ReqClient
  alias ContextBot.Repo
  alias ContextBot.Workflow.{Invocation, Store}

  @collection "app.bsky.feed.post"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}} = job)
      when is_binary(uri) and is_binary(cid) do
    dependencies = dependencies(job)

    case find_invocation(uri, cid) do
      %Invocation{stage: :reply_ready} = invocation ->
        claim_and_publish(invocation, dependencies)

      %Invocation{stage: :publishing} = invocation ->
        publish(invocation, dependencies)

      _missing_or_finished ->
        :ok
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

  defp claim_and_publish(invocation, dependencies) do
    case Store.transition(invocation, :reply_ready, :publishing, %{}, nil) do
      {:ok, claimed} ->
        publish(claimed, dependencies)

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp publish(invocation, dependencies) do
    repo = dependencies.settings.bot_did

    if valid_intent?(repo, invocation.reply_rkey, invocation.reply_record) do
      reconcile_before_put(invocation, repo, dependencies)
    else
      fail_conflict(invocation, "invalid_frozen_intent", dependencies.now.())
    end
  end

  defp reconcile_before_put(invocation, repo, dependencies) do
    case get_record(invocation, repo, dependencies.client) do
      {:match, uri, cid} -> complete(invocation, uri, cid, dependencies.now.())
      :missing -> put_record(invocation, repo, dependencies)
      :conflict -> fail_conflict(invocation, "record_mismatch", dependencies.now.())
      {:auth, _reason} -> fail_auth(invocation, dependencies.now.())
      {:retry, reason} -> retry_or_exhausted(invocation, reason, dependencies)
      :invalid -> fail_conflict(invocation, "invalid_provider_response", dependencies.now.())
    end
  end

  defp put_record(invocation, repo, dependencies) do
    result =
      dependencies.client.put_record(
        repo,
        @collection,
        invocation.reply_rkey,
        invocation.reply_record
      )

    case result do
      {:ok, status, _headers, _body} when status in 200..299 ->
        reconcile_after_put(invocation, repo, dependencies, :reconciliation_pending)

      {:error, reason} when reason in [:timeout, :invalid_swap] ->
        reconcile_after_put(invocation, repo, dependencies, reason)

      {:error, reason} when reason in [:unauthorized, :session_unavailable] ->
        fail_auth(invocation, dependencies.now.())

      {:error, {:permanent, _status}} ->
        fail_conflict(invocation, "publication_rejected", dependencies.now.())

      {:error, reason} ->
        retry_or_exhausted(invocation, reason, dependencies)

      _invalid ->
        fail_conflict(invocation, "invalid_provider_response", dependencies.now.())
    end
  end

  defp reconcile_after_put(invocation, repo, dependencies, missing_reason) do
    case get_record(invocation, repo, dependencies.client) do
      {:match, uri, cid} -> complete(invocation, uri, cid, dependencies.now.())
      :missing -> retry_or_exhausted(invocation, missing_reason, dependencies)
      :conflict -> fail_conflict(invocation, "record_mismatch", dependencies.now.())
      {:auth, _reason} -> fail_auth(invocation, dependencies.now.())
      {:retry, reason} -> retry_or_exhausted(invocation, reason, dependencies)
      :invalid -> fail_conflict(invocation, "invalid_provider_response", dependencies.now.())
    end
  end

  defp get_record(invocation, repo, client) do
    case client.get_record(repo, @collection, invocation.reply_rkey) do
      {:ok, status, _headers, body} when status in 200..299 ->
        compare_record(body, repo, invocation.reply_rkey, invocation.reply_record)

      {:error, :record_not_found} ->
        :missing

      {:error, reason} when reason in [:unauthorized, :session_unavailable] ->
        {:auth, reason}

      {:error, {:permanent, _status}} ->
        :invalid

      {:error, reason} ->
        {:retry, reason}

      _invalid ->
        :invalid
    end
  end

  defp compare_record(body, repo, rkey, intended_record) do
    expected_uri = "at://#{repo}/#{@collection}/#{rkey}"

    case body do
      %{"uri" => ^expected_uri, "cid" => cid, "value" => ^intended_record}
      when is_binary(cid) and cid != "" ->
        {:match, expected_uri, cid}

      %{} ->
        :conflict

      _invalid ->
        :invalid
    end
  end

  defp complete(invocation, uri, cid, completed_at) do
    transition_terminal(invocation, :complete, %{reply_uri: uri, reply_cid: cid}, completed_at)
  end

  defp fail_auth(invocation, completed_at) do
    transition_terminal(
      invocation,
      :failed,
      %{
        failure_category: :publication_auth,
        failure_detail: %{"reason" => "authorization_required"}
      },
      completed_at
    )
  end

  defp fail_conflict(invocation, reason, completed_at) do
    transition_terminal(
      invocation,
      :failed,
      %{
        failure_category: :publication_conflict,
        failure_detail: %{"reason" => reason}
      },
      completed_at
    )
  end

  defp retry_or_exhausted(invocation, _reason, %{final_attempt?: true} = dependencies) do
    fail_conflict(invocation, "retry_exhausted", dependencies.now.())
  end

  defp retry_or_exhausted(_invocation, reason, _dependencies), do: {:error, reason}

  defp transition_terminal(invocation, stage, attrs, completed_at) do
    attrs = Map.put(attrs, :completed_at, completed_at)

    case Store.transition(invocation, :publishing, stage, attrs, nil) do
      {:ok, _terminal} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp valid_intent?(repo, rkey, record) do
    is_binary(repo) and repo != "" and is_binary(rkey) and rkey != "" and is_map(record)
  end

  defp dependencies(job) do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      client: Keyword.get(config, :client, ReqClient),
      final_attempt?: final_attempt?(job),
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: maximum})
       when is_integer(attempt) and is_integer(maximum) and maximum > 0,
       do: attempt >= maximum

  defp final_attempt?(%Oban.Job{}), do: false
end
