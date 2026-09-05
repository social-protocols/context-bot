defmodule ContextBot.Workers.FollowerPostWorker do
  @moduledoc """
  Puts the follower-feed quote+Reader card after Standard Reader has indexed.

  Thread replies complete on the current schedule. This worker only puts the
  follower record once `ReaderReady.ensure/2` reports ready (`reader_ready_at`
  or `ReaderIndex` `:indexed`). `:not_indexed` and `:ambiguous` snooze with
  backoff. A minute cron reconsider re-enqueues complete invocations that are
  still waiting.

  Give-up: stop retrying 7 days after `completed_at` rather than posting an
  unindexed card. Prefer posting once indexed inside that window.
  """

  use Oban.Worker, queue: :reply, max_attempts: 20

  import Ecto.Query

  alias ContextBot.ATProto.{Client, ReqClient, TID}
  alias ContextBot.{Operations, Repo}
  alias ContextBot.Reply.FollowerPost
  alias ContextBot.StandardSite.{ReaderIndex, ReaderReady}
  alias ContextBot.Workflow.{Invocation, Store}

  @collection "app.bsky.feed.post"
  @default_backoff_seconds 15
  @maximum_backoff_seconds 900
  @max_wait_seconds 7 * 24 * 60 * 60
  @reconsider_batch 25
  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invocation_id" => id}} = job)
      when is_integer(id) and id > 0 do
    dependencies = dependencies(job)

    case Repo.get(Invocation, id) do
      nil ->
        :ok

      %Invocation{dry_run: true} ->
        :ok

      invocation ->
        logged_publish(invocation, job, dependencies)
    end
  end

  def perform(%Oban.Job{}) do
    reconsider_pending(dependencies(%Oban.Job{attempt: 1}))
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: backoff_seconds(attempt)

  @spec enqueue(Invocation.t()) :: :ok | {:error, term()}
  def enqueue(%Invocation{id: id}) when is_integer(id) and id > 0 do
    changeset =
      Oban.Job.new(%{"invocation_id" => id},
        worker: __MODULE__,
        queue: :reply,
        unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]
      )

    case Repo.insert(changeset) do
      {:ok, %Oban.Job{}} ->
        :ok

      {:error, %Ecto.Changeset{} = invalid} ->
        if unique_job_conflict?(invalid), do: :ok, else: {:error, invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique_job_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp logged_publish(invocation, job, dependencies) do
    started_at = System.monotonic_time(:millisecond)
    result = publish(invocation, dependencies)

    Operations.log_attempt(invocation,
      attempt_kind: :follower_post,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: follower_failure(result)
    )

    result
  end

  defp follower_failure({:error, _reason}), do: :publication_conflict
  defp follower_failure(_result), do: nil

  defp publish(invocation, dependencies) do
    current = Repo.reload!(invocation)

    cond do
      published_follower?(current) ->
        :ok

      not FollowerPost.eligible?(current) ->
        :ok

      past_deadline?(current, dependencies.now.()) ->
        :ok

      true ->
        publish_when_ready(current, dependencies)
    end
  end

  defp publish_when_ready(invocation, dependencies) do
    case ReaderReady.ensure(invocation,
           check: dependencies.reader_check,
           now: dependencies.now.()
         ) do
      {:ready, ready} ->
        put_follower_post(ready, dependencies)

      {:wait, _reason, _updated} ->
        {:snooze, backoff_seconds(dependencies.attempt)}
    end
  end

  defp put_follower_post(invocation, dependencies) do
    case ensure_intent(invocation, dependencies) do
      {:ok, prepared} ->
        reconcile(prepared, dependencies)

      :skip ->
        :ok

      {:error, :already_published} ->
        :ok

      {:error, _reason} ->
        {:error, :follower_persist_failed}
    end
  end

  defp ensure_intent(invocation, dependencies) do
    if valid_intent?(
         invocation.reply_repo,
         invocation.follower_post_rkey,
         invocation.follower_post_record
       ) do
      {:ok, invocation}
    else
      freeze_intent(invocation, dependencies)
    end
  end

  defp freeze_intent(invocation, dependencies) do
    created_at = dependencies.now.()

    case FollowerPost.build(invocation, created_at) do
      {:ok, record} ->
        rkey = dependencies.tid.(DateTime.to_unix(created_at, :microsecond))

        Store.record_follower_post(invocation, %{
          follower_post_rkey: rkey,
          follower_post_record: record
        })

      {:error, _reason} ->
        :skip
    end
  end

  defp reconcile(invocation, dependencies) do
    case get_record(invocation, dependencies) do
      {:match, uri, cid} ->
        record_publication(invocation, uri, cid)

      :missing ->
        put_record(invocation, dependencies)

      :conflict ->
        :ok

      :auth ->
        {:error, :unauthorized}

      {:retry, reason} ->
        {:error, reason}

      :invalid ->
        :ok
    end
  end

  defp put_record(invocation, dependencies) do
    current = Repo.reload!(invocation)

    current
    |> put_frozen_record(dependencies)
    |> reconcile_after_put(current, dependencies)
  end

  defp put_frozen_record(current, dependencies) do
    dependencies.client.put_record(
      current.reply_repo,
      @collection,
      current.follower_post_rkey,
      current.follower_post_record
    )
  end

  defp reconcile_after_put({:ok, status, _headers, _body}, current, dependencies)
       when status in 200..299 do
    case get_record(current, dependencies) do
      {:match, uri, cid} -> record_publication(current, uri, cid)
      :missing -> {:error, :reconciliation_pending}
      other -> normalize_reconcile(other)
    end
  end

  defp reconcile_after_put({:error, reason}, _current, _dependencies)
       when reason in [:unauthorized, :session_unavailable],
       do: {:error, reason}

  defp reconcile_after_put({:error, reason}, _current, _dependencies) do
    case Client.permanent_status(reason) do
      status when is_integer(status) -> :ok
      nil -> {:error, reason}
    end
  end

  defp reconcile_after_put(_invalid, _current, _dependencies), do: :ok

  defp normalize_reconcile(:conflict), do: :ok
  defp normalize_reconcile(:auth), do: {:error, :unauthorized}
  defp normalize_reconcile({:retry, reason}), do: {:error, reason}
  defp normalize_reconcile(:invalid), do: :ok

  defp get_record(invocation, dependencies) do
    current = Repo.reload!(invocation)

    case dependencies.client.get_record(
           current.reply_repo,
           @collection,
           current.follower_post_rkey
         ) do
      {:ok, status, _headers, body} when status in 200..299 ->
        compare_record(
          body,
          current.reply_repo,
          current.follower_post_rkey,
          current.follower_post_record
        )

      {:error, :record_not_found} ->
        :missing

      {:error, reason} when reason in [:unauthorized, :session_unavailable] ->
        :auth

      {:error, reason} ->
        classify_get_error(reason)

      _invalid ->
        :invalid
    end
  end

  defp classify_get_error(reason) do
    case Client.permanent_status(reason) do
      403 -> :auth
      status when is_integer(status) -> :invalid
      nil -> {:retry, reason}
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

  defp record_publication(invocation, uri, cid) do
    case Store.record_follower_post(invocation, %{
           follower_post_uri: uri,
           follower_post_cid: cid
         }) do
      {:ok, _updated} -> :ok
      {:error, :already_published} -> :ok
      {:error, _reason} -> {:error, :follower_persist_failed}
    end
  end

  defp reconsider_pending(dependencies) do
    pending_follower_posts(dependencies.now.())
    |> Enum.filter(&FollowerPost.eligible?/1)
    |> Enum.each(fn invocation ->
      _ = enqueue(invocation)
    end)

    :ok
  end

  defp pending_follower_posts(now) do
    cutoff = DateTime.add(now, -@max_wait_seconds, :second)

    Invocation
    |> where([invocation], invocation.stage == :complete)
    |> where([invocation], invocation.dry_run == false)
    |> where([invocation], invocation.no_reply == false)
    |> where([invocation], is_nil(invocation.follower_post_uri))
    |> where([invocation], not is_nil(invocation.standard_site_document_uri))
    |> where([invocation], not is_nil(invocation.root_uri))
    |> where(
      [invocation],
      is_nil(invocation.completed_at) or invocation.completed_at >= ^cutoff
    )
    |> order_by([invocation], asc: invocation.id)
    |> limit(^@reconsider_batch)
    |> Repo.all()
  end

  defp published_follower?(%Invocation{follower_post_uri: uri, follower_post_cid: cid})
       when is_binary(uri) and uri != "" and is_binary(cid) and cid != "",
       do: true

  defp published_follower?(_invocation), do: false

  defp past_deadline?(%Invocation{completed_at: %DateTime{} = completed_at}, now) do
    DateTime.diff(now, completed_at, :second) >= @max_wait_seconds
  end

  defp past_deadline?(_invocation, _now), do: false

  defp valid_intent?(repo, rkey, record) do
    is_binary(repo) and Regex.match?(@did_regex, repo) and is_binary(rkey) and rkey != "" and
      is_map(record)
  end

  defp backoff_seconds(attempt) when is_integer(attempt) and attempt > 0 do
    exponent = attempt |> Kernel.-(1) |> min(6)
    min(@default_backoff_seconds * Integer.pow(2, exponent), @maximum_backoff_seconds)
  end

  defp backoff_seconds(_attempt), do: @default_backoff_seconds

  defp dependencies(job) do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      attempt: job.attempt,
      client: Keyword.get(config, :client, ReqClient),
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      reader_check: Keyword.get(config, :reader_check, &ReaderIndex.check/1),
      tid: Keyword.get(config, :tid, &TID.generate/1)
    }
  end
end
