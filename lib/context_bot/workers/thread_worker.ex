defmodule ContextBot.Workers.ThreadWorker do
  @moduledoc """
  Fetches and freezes the ancestor-only thread snapshot before research may begin.

  The external fetch and canonicalization run outside SQLite transactions. The completed
  snapshot and future research job are committed together through the workflow store.
  """

  use Oban.Worker, queue: :thread, max_attempts: 10

  import Ecto.Query

  alias ContextBot.ATProto.{PublicClient, ReqClient, TID}
  alias ContextBot.{Operations, Repo}
  alias ContextBot.Reply.Intent
  alias ContextBot.Thread.Canonicalizer
  alias ContextBot.Workflow.{Invocation, Store}

  @research_worker "ContextBot.Workers.ResearchWorker"
  @reply_worker "ContextBot.Workers.ReplyWorker"
  @maximum_backoff_seconds 300
  @image_limit_reply "I can analyze up to four images at a time, but this thread contains more than that."

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}} = job)
      when is_binary(uri) and is_binary(cid) do
    case find_invocation(uri, cid) do
      %Invocation{stage: :capturing_thread} = invocation ->
        logged_capture(invocation, job, dependencies())

      _missing_or_unclaimable ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: :ok

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) when is_integer(attempt) and attempt > 0 do
    exponent = attempt |> Kernel.-(1) |> min(5)
    min(15 * Integer.pow(2, exponent), @maximum_backoff_seconds)
  end

  def backoff(%Oban.Job{}), do: 15

  defp find_invocation(uri, cid) do
    Invocation
    |> where(
      [invocation],
      invocation.invocation_uri == ^uri and invocation.notification_cid == ^cid
    )
    |> Repo.one()
  end

  defp capture(invocation, job, dependencies) do
    {client, uri} = thread_source(invocation, dependencies)

    result =
      fetch_with_timeout(
        client,
        uri,
        dependencies.settings.thread_parent_height,
        dependencies.fetch_timeout_ms
      )

    result
    |> handle_fetch(invocation, dependencies)
    |> terminalize_exhausted_retry(invocation, job)
  end

  defp logged_capture(invocation, job, dependencies) do
    started_at = System.monotonic_time(:millisecond)
    result = capture(invocation, job, dependencies)
    {oban_result, media_attributes} = capture_observation(result)

    Operations.log_attempt(invocation,
      attempt_kind: :thread,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: thread_failure(oban_result),
      media_disposition: Keyword.get(media_attributes, :media_disposition),
      image_count: Keyword.get(media_attributes, :image_count)
    )

    oban_result
  end

  defp capture_observation({:media_capture, disposition, image_count}) do
    {:ok, [media_disposition: disposition, image_count: image_count]}
  end

  defp capture_observation(result), do: {result, []}

  defp thread_failure({:error, _reason}), do: :thread_unavailable
  defp thread_failure(_result), do: nil

  defp terminalize_exhausted_retry({:error, _reason}, invocation, %Oban.Job{
         attempt: attempt,
         max_attempts: max_attempts
       })
       when is_integer(attempt) and is_integer(max_attempts) and attempt >= max_attempts,
       do: fail_thread(invocation, "retry_exhausted")

  defp terminalize_exhausted_retry(result, _invocation, _job), do: result

  defp fetch_with_timeout(client, uri, parent_height, timeout_ms) do
    task = Task.async(fn -> client.get_post_thread(uri, parent_height) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, {:transient, :transport}}
    end
  end

  defp handle_fetch({:ok, status, _headers, body}, invocation, dependencies)
       when status in 200..299 and is_map(body) do
    case within_response_limit(body, dependencies.settings.max_response_bytes) do
      :ok ->
        body
        |> canonicalize(invocation, dependencies)
        |> handle_canonicalization(invocation, body, dependencies)

      {:error, :response_too_large} ->
        fail_thread(invocation, "response_too_large")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_fetch({:error, :response_too_large}, invocation, _dependencies),
    do: fail_thread(invocation, "response_too_large")

  defp handle_fetch({:error, :record_not_found}, invocation, _dependencies),
    do: fail_thread(invocation, "target_unavailable")

  defp handle_fetch({:error, {:permanent, _status}}, invocation, _dependencies),
    do: fail_thread(invocation, "target_unavailable")

  defp handle_fetch({:error, {:permanent, _status, _detail}}, invocation, _dependencies),
    do: fail_thread(invocation, "target_unavailable")

  defp handle_fetch({:ok, status, _headers, _invalid_body}, invocation, _dependencies)
       when status in 200..299,
       do: fail_thread(invocation, "invalid_thread")

  defp handle_fetch({:error, reason}, _invocation, _dependencies), do: {:error, reason}
  defp handle_fetch(_invalid_response, _invocation, _dependencies), do: {:error, :invalid_thread}

  defp handle_canonicalization({:ok, canonical}, invocation, raw_thread, dependencies) do
    with :ok <-
           persist_handoff(invocation, raw_thread, canonical, dependencies.research_job_builder) do
      {:media_capture, :supported, length(canonical.media)}
    end
  end

  defp handle_canonicalization(
         {:unsupported_media,
          %{reason: :image_limit_exceeded, image_count: image_count, canonical: canonical}},
         invocation,
         raw_thread,
         dependencies
       ) do
    with :ok <-
           persist_capability_handoff(
             invocation,
             raw_thread,
             canonical,
             :image_limit_exceeded,
             dependencies
           ) do
      {:media_capture, :image_limit_exceeded, image_count}
    end
  end

  defp handle_canonicalization(
         {:error, :target_unavailable},
         invocation,
         _raw_thread,
         _dependencies
       ),
       do: fail_thread(invocation, "target_unavailable")

  defp handle_canonicalization(
         {:error, :invalid_thread},
         invocation,
         _raw_thread,
         _dependencies
       ),
       do: fail_thread(invocation, "invalid_thread")

  defp handle_canonicalization({:error, reason}, _invocation, _raw_thread, _dependencies),
    do: {:error, reason}

  defp within_response_limit(body, limit) do
    case Jason.encode(body) do
      {:ok, encoded} when byte_size(encoded) <= limit -> :ok
      {:ok, _oversized} -> {:error, :response_too_large}
      {:error, _invalid_json} -> {:error, :invalid_thread}
    end
  end

  defp thread_source(%Invocation{dry_run: true, target_uri: uri}, dependencies),
    do: {dependencies.public_client, uri}

  defp thread_source(%Invocation{invocation_uri: uri}, dependencies),
    do: {dependencies.client, uri}

  defp canonicalize(body, %Invocation{dry_run: true} = invocation, dependencies) do
    dependencies.canonicalizer.build_dry_run(body, %{
      target_uri: invocation.target_uri,
      invocation_text: invocation.invocation_text,
      parent_height: dependencies.settings.thread_parent_height
    })
  end

  defp canonicalize(body, invocation, dependencies) do
    dependencies.canonicalizer.build(body, %{
      bot_did: dependencies.settings.bot_did,
      invocation_uri: invocation.invocation_uri,
      notification_cid: invocation.notification_cid,
      parent_height: dependencies.settings.thread_parent_height
    })
  end

  defp persist_handoff(invocation, raw_thread, canonical, research_job_builder) do
    next_job = research_job_builder.(invocation)

    attrs = %{
      raw_thread: raw_thread,
      canonical_thread: canonical.text,
      canonical_thread_version: Integer.to_string(canonical.version),
      canonical_media: canonical.media,
      contains_video: canonical.contains_video,
      root_uri: canonical.root["uri"],
      root_cid: canonical.root["cid"],
      current_cid: canonical.current_cid
    }

    case Store.transition(invocation, :capturing_thread, :thread_ready, attrs, next_job) do
      {:ok, _thread_ready} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp persist_capability_handoff(
         %Invocation{dry_run: true} = invocation,
         raw_thread,
         canonical,
         reason,
         dependencies
       ) do
    completed_at = dependencies.now.()

    attrs =
      raw_thread
      |> canonical_attrs(canonical)
      |> Map.merge(%{
        anthropic_messages: nil,
        anthropic_usage: zero_usage(),
        selected_reply: capability_reply(reason),
        reply_validation: capability_validation(reason),
        reply_repo: nil,
        reply_rkey: nil,
        reply_record: nil,
        completed_at: completed_at,
        failure_category: nil,
        failure_detail: nil
      })

    transition_capability(invocation, :complete, attrs, nil)
  end

  defp persist_capability_handoff(invocation, raw_thread, canonical, reason, dependencies) do
    created_at = dependencies.now.()

    intent_invocation = %{
      invocation
      | current_cid: canonical.current_cid,
        root_uri: canonical.root["uri"],
        root_cid: canonical.root["cid"]
    }

    case dependencies.intent_builder.(
           intent_invocation,
           capability_reply(reason),
           dependencies.settings.bot_did,
           created_at,
           dependencies.tid_generator
         ) do
      {:ok, intent} ->
        attrs =
          raw_thread
          |> canonical_attrs(canonical)
          |> Map.merge(%{
            anthropic_messages: nil,
            anthropic_usage: zero_usage(),
            selected_reply: capability_reply(reason),
            reply_validation: capability_validation(reason),
            reply_repo: intent.reply_repo,
            reply_rkey: intent.reply_rkey,
            reply_record: intent.reply_record,
            completed_at: nil,
            failure_category: nil,
            failure_detail: nil
          })

        next_job = dependencies.reply_job_builder.(intent_invocation)
        transition_capability(invocation, :reply_ready, attrs, next_job)

      {:error, intent_reason} ->
        fail_thread(invocation, safe_reason(intent_reason))
    end
  end

  defp transition_capability(invocation, next_stage, attrs, next_job) do
    case Store.transition(
           invocation,
           :capturing_thread,
           next_stage,
           attrs,
           next_job
         ) do
      {:ok, _transitioned} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp canonical_attrs(raw_thread, canonical) do
    %{
      raw_thread: raw_thread,
      canonical_thread: canonical.text,
      canonical_thread_version: Integer.to_string(canonical.version),
      canonical_media: canonical.media,
      contains_video: canonical.contains_video,
      root_uri: canonical.root["uri"],
      root_cid: canonical.root["cid"],
      current_cid: canonical.current_cid
    }
  end

  defp capability_reply(:image_limit_exceeded), do: @image_limit_reply

  defp capability_validation(reason) do
    %{
      "result" => "unsupported_media",
      "reason" => Atom.to_string(reason),
      "source" => "local"
    }
  end

  defp zero_usage do
    %{
      "attempts" => [],
      "continuations" => 0,
      "response_count" => 0,
      "tool_uses" => 0,
      "totals" => %{"input_tokens" => 0, "output_tokens" => 0}
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "invalid_reply_intent"

  defp fail_thread(invocation, reason) do
    case Store.transition(
           invocation,
           :capturing_thread,
           :failed,
           %{
             failure_category: :thread_unavailable,
             failure_detail: %{"reason" => reason},
             completed_at: DateTime.utc_now()
           },
           nil
         ) do
      {:ok, _failed} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp research_job(invocation) do
    queue = if invocation.dry_run, do: :dry_research, else: :research

    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @research_worker,
      queue: queue
    )
  end

  defp reply_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @reply_worker,
      queue: :reply
    )
  end

  defp dependencies do
    config = Application.get_env(:context_bot, __MODULE__, [])
    settings = Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))

    %{
      canonicalizer: Keyword.get(config, :canonicalizer, Canonicalizer),
      client: Keyword.get(config, :client, ReqClient),
      public_client: Keyword.get(config, :public_client, PublicClient),
      fetch_timeout_ms: Keyword.get(config, :fetch_timeout_ms, settings.thread_fetch_timeout_ms),
      intent_builder: Keyword.get(config, :intent_builder, &Intent.build/5),
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      reply_job_builder: Keyword.get(config, :reply_job_builder, &reply_job/1),
      research_job_builder: Keyword.get(config, :research_job_builder, &research_job/1),
      settings: settings,
      tid_generator: Keyword.get(config, :tid_generator, &TID.generate/1)
    }
  end
end
