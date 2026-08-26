defmodule ContextBot.Workers.ReplyWorker do
  @moduledoc """
  Reconciles one frozen Bluesky reply intent at its deterministic repository key.

  Publication is create-only. Every attempt reads before writing, and every possible write is
  accepted only after a subsequent read returns the exact persisted record and coordinates.

  Authorization failures stop in `failed/publication_auth` rather than retrying. After repairing
  credentials, an operator may deliberately resume the unchanged intent by resetting the stage to
  `reply_ready` and clearing the terminal markers while retaining `reply_repo`, `reply_rkey`, and
  `reply_record`; the worker never performs that intervention automatically.
  """

  use Oban.Worker, queue: :reply, max_attempts: 10

  import Ecto.Query

  alias ContextBot.ATProto.ReqClient
  alias ContextBot.{Operations, Repo}
  alias ContextBot.Workflow.{Invocation, Store}

  @collection "app.bsky.feed.post"
  @default_claim_lease_ms 300_000
  @default_backoff_seconds 15
  @maximum_backoff_seconds 300
  @maximum_retry_after_seconds 3_600
  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/
  @retry_after_regex ~r/\A[0-9]+\z/

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}} = job)
      when is_binary(uri) and is_binary(cid) do
    dependencies = dependencies(job)

    case find_invocation(uri, cid) do
      nil -> :ok
      %Invocation{dry_run: true} -> :ok
      invocation -> claim_and_publish(invocation, job, claim_token(job), dependencies)
    end
  end

  def perform(%Oban.Job{}), do: :ok

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job) do
    case retry_after(job.unsaved_error) do
      {:ok, seconds} -> min(seconds, @maximum_retry_after_seconds)
      :error -> default_backoff(job.attempt)
    end
  end

  defp find_invocation(uri, cid) do
    Invocation
    |> where(
      [invocation],
      invocation.invocation_uri == ^uri and invocation.notification_cid == ^cid
    )
    |> Repo.one()
  end

  defp claim_and_publish(invocation, job, token, dependencies) do
    now = dependencies.now.()
    stale_before = DateTime.add(now, -dependencies.claim_lease_ms, :millisecond)

    case Store.claim_publication(invocation, token, now, stale_before) do
      {:ok, claimed} ->
        logged_publish(claimed, job, token, dependencies)

      {:error, reason} when reason in [:busy, :stale_stage] ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp logged_publish(invocation, job, token, dependencies) do
    started_at = System.monotonic_time(:millisecond)
    result = publish(invocation, token, dependencies)

    Operations.log_attempt(invocation,
      attempt_kind: :publication,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: publication_failure(invocation, result)
    )

    result
  end

  defp publication_failure(invocation, result) do
    case {Repo.reload!(invocation), result} do
      {%Invocation{stage: :failed, failure_category: category}, _result} -> category
      {_nonterminal_or_complete, {:error, _reason}} -> :publication_conflict
      {_nonterminal_or_complete, _result} -> nil
    end
  end

  defp publish(invocation, token, dependencies) do
    if valid_intent?(invocation.reply_repo, invocation.reply_rkey, invocation.reply_record) do
      reconcile_before_put(invocation, token, dependencies)
    else
      fail_conflict(invocation, token, "invalid_frozen_intent", dependencies.now.())
    end
  end

  defp reconcile_before_put(invocation, token, dependencies) do
    case get_record(invocation, token, dependencies) do
      {:match, uri, cid} ->
        complete(invocation, token, uri, cid, dependencies.now.())

      :missing ->
        put_record(invocation, token, dependencies)

      :conflict ->
        fail_conflict(invocation, token, "record_mismatch", dependencies.now.())

      :auth ->
        fail_auth(invocation, token, dependencies.now.())

      {:retry, reason} ->
        retry_or_exhausted(invocation, token, reason, dependencies)

      :invalid ->
        fail_conflict(invocation, token, "invalid_provider_response", dependencies.now.())

      :stale_claim ->
        :ok
    end
  end

  defp put_record(invocation, token, dependencies) do
    case guarded_put(invocation, token, dependencies) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        reconcile_after_put(invocation, token, dependencies, :reconciliation_pending)

      {:error, reason} when reason in [:unauthorized, :session_unavailable] ->
        fail_auth(invocation, token, dependencies.now.())

      {:error, {:permanent, 403}} ->
        fail_auth(invocation, token, dependencies.now.())

      {:error, {:permanent, _status}} ->
        fail_conflict(invocation, token, "publication_rejected", dependencies.now.())

      {:error, reason} ->
        reconcile_after_put(invocation, token, dependencies, reason)

      :stale_claim ->
        :ok

      _invalid ->
        fail_conflict(invocation, token, "invalid_provider_response", dependencies.now.())
    end
  end

  defp reconcile_after_put(invocation, token, dependencies, missing_reason) do
    case get_record(invocation, token, dependencies) do
      {:match, uri, cid} ->
        complete(invocation, token, uri, cid, dependencies.now.())

      :missing ->
        retry_or_exhausted(invocation, token, missing_reason, dependencies)

      :conflict ->
        fail_conflict(invocation, token, "record_mismatch", dependencies.now.())

      :auth ->
        fail_auth(invocation, token, dependencies.now.())

      {:retry, reason} ->
        retry_or_exhausted(invocation, token, reason, dependencies)

      :invalid ->
        fail_conflict(invocation, token, "invalid_provider_response", dependencies.now.())

      :stale_claim ->
        :ok
    end
  end

  defp get_record(invocation, token, dependencies) do
    case Store.renew_publication_claim(invocation, token, dependencies.now.()) do
      {:ok, current} -> request_record(current, dependencies.client)
      {:error, :stale_claim} -> :stale_claim
    end
  end

  defp request_record(invocation, client) do
    case client.get_record(invocation.reply_repo, @collection, invocation.reply_rkey) do
      {:ok, status, _headers, body} when status in 200..299 ->
        compare_record(
          body,
          invocation.reply_repo,
          invocation.reply_rkey,
          invocation.reply_record
        )

      {:error, :record_not_found} ->
        :missing

      {:error, reason} when reason in [:unauthorized, :session_unavailable] ->
        :auth

      {:error, {:permanent, 403}} ->
        :auth

      {:error, {:permanent, _status}} ->
        :invalid

      {:error, reason} ->
        {:retry, reason}

      _invalid ->
        :invalid
    end
  end

  defp guarded_put(invocation, token, dependencies) do
    case Store.renew_publication_claim(invocation, token, dependencies.now.()) do
      {:ok, current} ->
        dependencies.client.put_record(
          current.reply_repo,
          @collection,
          current.reply_rkey,
          current.reply_record
        )

      {:error, :stale_claim} ->
        :stale_claim
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

  defp complete(invocation, token, uri, cid, completed_at) do
    if has_part2?(invocation) do
      publish_part2(invocation, token, uri, cid, completed_at)
    else
      complete_single_part(invocation, token, uri, cid, completed_at)
    end
  end

  defp complete_single_part(invocation, token, uri, cid, completed_at) do
    transition_terminal(
      invocation,
      token,
      :complete,
      %{reply_uri: uri, reply_cid: cid},
      completed_at
    )
  end

  defp publish_part2(invocation, token, part1_uri, part1_cid, part1_completed_at) do
    case reconcile_part2(invocation, token, part1_uri, part1_cid, part1_completed_at) do
      {:ok, part2_uri, part2_cid} ->
        transition_terminal(
          invocation,
          token,
          :complete,
          %{
            reply_uri: part1_uri,
            reply_cid: part1_cid,
            reply_part2_uri: part2_uri,
            reply_part2_cid: part2_cid
          },
          part1_completed_at
        )

      :stale_claim ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_part2(invocation, token, part1_uri, part1_cid, _completed_at) do
    dependencies = dependencies(%Oban.Job{attempt: 1, max_attempts: 10})

    case Store.renew_publication_claim(invocation, token, dependencies.now.()) do
      {:ok, current} ->
        publish_part2_record(current, dependencies, part1_uri, part1_cid)

      {:error, :stale_claim} ->
        :stale_claim
    end
  end

  defp publish_part2_record(invocation, dependencies, part1_uri, part1_cid) do
    case rebuild_part2_record(invocation, part1_uri, part1_cid) do
      {:ok, corrected_record} ->
        case get_part2_record(invocation, dependencies.client, corrected_record) do
          {:match, uri, cid} ->
            {:ok, uri, cid}

          :missing ->
            put_part2_record(invocation, dependencies, corrected_record)

          :conflict ->
            {:error, :part2_conflict}
        end

      {:error, _reason} ->
        {:error, :part2_record_invalid}
    end
  end

  defp put_part2_record(invocation, dependencies, corrected_record) do
    case dependencies.client.put_record(
           invocation.reply_repo,
           @collection,
           invocation.reply_part2_rkey,
           corrected_record
         ) do
      {:ok, status, _headers, _body} when status in 200..299 ->
        reconcile_part2_after_put(invocation, dependencies.client, corrected_record)

      {:error, _reason} ->
        {:error, :part2_put_failed}

      _invalid ->
        {:error, :part2_invalid_response}
    end
  end

  defp reconcile_part2_after_put(invocation, client, corrected_record) do
    case get_part2_record(invocation, client, corrected_record) do
      {:match, uri, cid} ->
        {:ok, uri, cid}

      _other ->
        {:error, :part2_reconciliation_failed}
    end
  end

  defp get_part2_record(invocation, client, corrected_record) do
    case client.get_record(invocation.reply_repo, @collection, invocation.reply_part2_rkey) do
      {:ok, status, _headers, body} when status in 200..299 ->
        compare_part2_record(
          body,
          invocation.reply_repo,
          invocation.reply_part2_rkey,
          corrected_record
        )

      {:error, :record_not_found} ->
        :missing

      {:error, _reason} ->
        :conflict

      _invalid ->
        :conflict
    end
  end

  defp compare_part2_record(body, repo, rkey, intended_record) do
    expected_uri = "at://#{repo}/#{@collection}/#{rkey}"

    case body do
      %{"uri" => ^expected_uri, "cid" => cid, "value" => ^intended_record}
      when is_binary(cid) and cid != "" ->
        {:match, expected_uri, cid}

      %{} ->
        :conflict

      _invalid ->
        :conflict
    end
  end

  defp has_part2?(%Invocation{reply_part2_record: record}) when is_map(record), do: true
  defp has_part2?(_invocation), do: false

  defp rebuild_part2_record(
         %Invocation{
           reply_part2_record: frozen_record,
           root_uri: root_uri,
           root_cid: root_cid
         },
         part1_uri,
         part1_cid
       )
       when is_map(frozen_record) and is_binary(part1_uri) and is_binary(part1_cid) do
    alias ContextBot.ATProto.Post

    with {:ok, text} <- extract_text(frozen_record),
         {:ok, created_at} <- extract_created_at(frozen_record) do
      parent = %{"uri" => part1_uri, "cid" => part1_cid}
      root = build_root_ref(root_uri, root_cid)
      Post.build(text, nil, parent, root, created_at)
    end
  end

  defp rebuild_part2_record(_invocation, _part1_uri, _part1_cid),
    do: {:error, :invalid_part2_data}

  defp build_root_ref(nil, nil), do: nil

  defp build_root_ref(root_uri, root_cid)
       when is_binary(root_uri) and is_binary(root_cid),
       do: %{"uri" => root_uri, "cid" => root_cid}

  defp build_root_ref(_root_uri, _root_cid), do: nil

  defp extract_text(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp extract_text(_record), do: {:error, :missing_text}

  defp extract_created_at(%{"createdAt" => iso_string}) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _error -> {:error, :invalid_created_at}
    end
  end

  defp extract_created_at(_record), do: {:error, :missing_created_at}

  defp fail_auth(invocation, token, completed_at) do
    transition_terminal(
      invocation,
      token,
      :failed,
      %{
        failure_category: :publication_auth,
        failure_detail: %{"reason" => "authorization_required"}
      },
      completed_at
    )
  end

  defp fail_conflict(invocation, token, reason, completed_at) do
    transition_terminal(
      invocation,
      token,
      :failed,
      %{
        failure_category: :publication_conflict,
        failure_detail: %{"reason" => reason}
      },
      completed_at
    )
  end

  defp retry_or_exhausted(
         invocation,
         token,
         _reason,
         %{final_attempt?: true} = dependencies
       ) do
    fail_conflict(invocation, token, "retry_exhausted", dependencies.now.())
  end

  defp retry_or_exhausted(_invocation, _token, reason, _dependencies), do: {:error, reason}

  defp transition_terminal(invocation, token, stage, attrs, completed_at) do
    case Store.transition_publication(invocation, token, stage, attrs, completed_at) do
      {:ok, _terminal} ->
        :ok

      {:error, :stale_claim} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp valid_intent?(repo, rkey, record) do
    is_binary(repo) and Regex.match?(@did_regex, repo) and is_binary(rkey) and rkey != "" and
      is_map(record)
  end

  defp claim_token(%Oban.Job{id: id}) when is_integer(id), do: "publication-job-#{id}"

  defp claim_token(%Oban.Job{}) do
    unique = System.unique_integer([:positive, :monotonic])
    "publication-process-#{inspect(self())}-#{unique}"
  end

  defp retry_after(%{
         reason: %Oban.PerformError{reason: {:error, {:rate_limited, retry_after}}}
       }),
       do: parse_retry_after(retry_after)

  defp retry_after(%{reason: {:error, {:rate_limited, retry_after}}}),
    do: parse_retry_after(retry_after)

  defp retry_after(%{reason: {:rate_limited, retry_after}}),
    do: parse_retry_after(retry_after)

  defp retry_after(_unsaved_error), do: :error

  defp parse_retry_after(value) when is_binary(value) do
    if Regex.match?(@retry_after_regex, value), do: {:ok, String.to_integer(value)}, else: :error
  end

  defp parse_retry_after(_value), do: :error

  defp default_backoff(attempt) when is_integer(attempt) and attempt > 0 do
    exponent = attempt |> Kernel.-(1) |> min(5)
    min(@default_backoff_seconds * Integer.pow(2, exponent), @maximum_backoff_seconds)
  end

  defp default_backoff(_attempt), do: @default_backoff_seconds

  defp dependencies(job) do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      claim_lease_ms: Keyword.get(config, :claim_lease_ms, @default_claim_lease_ms),
      client: Keyword.get(config, :client, ReqClient),
      final_attempt?: final_attempt?(job),
      now: Keyword.get(config, :now, &DateTime.utc_now/0)
    }
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: maximum})
       when is_integer(attempt) and is_integer(maximum) and maximum > 0,
       do: attempt >= maximum

  defp final_attempt?(%Oban.Job{}), do: false
end
