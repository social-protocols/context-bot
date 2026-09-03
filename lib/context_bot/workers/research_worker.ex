defmodule ContextBot.Workers.ResearchWorker do
  @moduledoc """
  Claims durable thread snapshots, runs bounded research, and freezes publication intent.

  The exact reply record and all research evidence are committed in the same transaction that
  makes a future reply job visible. The runner performs every external call outside transactions.
  """

  use Oban.Worker, queue: :research, max_attempts: 5

  import Ecto.Query

  alias ContextBot.ATProto.{Client, TID}
  alias ContextBot.{LimitNotice, Operations, Repo}
  alias ContextBot.Reply.Intent
  alias ContextBot.Research.{Request, Runner}
  alias ContextBot.StandardSite.{Document, PageCopy, PromptDocument, Publication}
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
    result = run(invocation, job, token, dependencies)

    Operations.log_attempt(invocation,
      attempt_kind: :research,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: research_failure(invocation)
    )

    result
  end

  defp run(invocation, job, token, dependencies) do
    options =
      dependencies.runner_options
      |> put_runner_setting(dependencies.settings)
      |> put_runner_claim(token)
      |> put_force_new_attempt(job)

    case dependencies.runner.run(invocation, options) do
      {:ok, result} ->
        freeze_handoff(Repo.reload!(invocation), result, token, dependencies)

      {:wait, remaining_ms} ->
        {:snooze, snooze_seconds(remaining_ms)}

      {:deferred, %DateTime{} = defer_until, kind} ->
        defer_budget(invocation, defer_until, kind, token, dependencies)

      {:deferred, %DateTime{} = defer_until} ->
        defer_budget(invocation, defer_until, :research, token, dependencies)

      {:error, :stale_claim} ->
        :ok

      {:error, reason} ->
        fail_research(invocation, reason, dependencies.now.(), token)
    end
  end

  defp freeze_handoff(invocation, result, token, dependencies) do
    if no_reply_result?(result) do
      complete_without_reply(invocation, result, token, dependencies)
    else
      freeze_publishable(invocation, result, token, dependencies)
    end
  end

  defp freeze_publishable(%Invocation{dry_run: true} = invocation, result, token, dependencies) do
    completed_at = dependencies.now.()

    attrs = %{
      anthropic_messages: result.messages,
      anthropic_usage: result.usage,
      full_response: Map.get(result, :full_response),
      selected_reply: result.text,
      reply_validation: dry_run_validation(result),
      no_reply: false,
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

  defp freeze_publishable(invocation, result, token, dependencies) do
    created_at = dependencies.now.()
    bot_did = dependencies.settings.bot_did

    case create_standard_site_document(invocation, result, bot_did, created_at, dependencies) do
      {:error, document_error} ->
        fail_document_create(invocation, result, document_error, created_at, token)

      document ->
        freeze_reply_intent(
          invocation,
          result,
          token,
          dependencies,
          created_at,
          bot_did,
          document
        )
    end
  end

  defp freeze_reply_intent(
         invocation,
         result,
         token,
         dependencies,
         created_at,
         bot_did,
         document
       ) do
    reader_url = document_reader_url(document)
    intent_opts = if reader_url, do: [reader_url: reader_url], else: []

    intent_result =
      if Map.has_key?(result, :text_part2) do
        Intent.build_with_part2(
          invocation,
          result.text,
          result.text_part2,
          bot_did,
          created_at,
          dependencies.tid_generator,
          intent_opts
        )
      else
        dependencies.intent_builder.(
          invocation,
          result.text,
          bot_did,
          created_at,
          dependencies.tid_generator,
          intent_opts
        )
      end

    case intent_result do
      {:ok, intent} ->
        persist_reply_ready(
          invocation,
          result,
          token,
          dependencies,
          created_at,
          intent,
          document
        )

      {:error, reason} ->
        fail_research(invocation, reason, created_at, token)
    end
  end

  defp persist_reply_ready(
         invocation,
         result,
         token,
         dependencies,
         created_at,
         intent,
         document
       ) do
    attrs = %{
      anthropic_messages: result.messages,
      anthropic_usage: result.usage,
      full_response: Map.get(result, :full_response),
      selected_reply: result.text,
      reply_validation: result.validation,
      no_reply: false,
      standard_site_document_uri: document_uri(document),
      standard_site_document_rkey: document_rkey(document),
      reply_repo: intent.reply_repo,
      reply_rkey: intent.reply_rkey,
      reply_record: intent.reply_record,
      reply_part2_rkey: Map.get(intent, :reply_part2_rkey),
      reply_part2_record: Map.get(intent, :reply_part2_record),
      reply_part3_rkey: Map.get(intent, :reply_part3_rkey),
      reply_part3_record: Map.get(intent, :reply_part3_record),
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
  end

  defp complete_without_reply(invocation, result, token, dependencies) do
    completed_at = dependencies.now.()

    attrs = %{
      anthropic_messages: result.messages,
      anthropic_usage: result.usage,
      full_response: nil,
      selected_reply: nil,
      reply_validation: %{"result" => "no_reply", "repair_used" => false},
      no_reply: true,
      standard_site_document_uri: nil,
      standard_site_document_rkey: nil,
      reply_repo: nil,
      reply_rkey: nil,
      reply_record: nil,
      reply_part2_rkey: nil,
      reply_part2_record: nil,
      reply_part3_rkey: nil,
      reply_part3_record: nil,
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

  defp no_reply_result?(result) when is_map(result),
    do: Map.get(result, :disposition) == :no_reply

  defp dry_run_validation(result) do
    validation =
      case Map.get(result, :document_title) do
        title when is_binary(title) and title != "" ->
          Map.put(result.validation || %{}, "document_title", title)

        _missing ->
          result.validation || %{}
      end

    case Map.get(result, :text_part2) do
      part2 when is_binary(part2) and part2 != "" ->
        Map.put(validation, "text_part2", part2)

      _missing ->
        validation
    end
  end

  defp create_standard_site_document(invocation, result, repo, created_at, dependencies) do
    full_response = Map.get(result, :full_response)
    client = Map.fetch!(dependencies, :atproto_client)

    if is_binary(full_response) and byte_size(full_response) > 0 do
      case Publication.ensure_exists(client, repo, created_at) do
        {:ok, publication_uri} ->
          create_document_with_publication(
            invocation,
            result,
            client,
            repo,
            publication_uri,
            created_at,
            dependencies.settings
          )

        {:error, reason} ->
          fail_standard_site(invocation, "site.standard.publication", reason)
      end
    else
      :skipped
    end
  end

  defp create_document_with_publication(
         invocation,
         result,
         client,
         repo,
         publication_uri,
         created_at,
         settings
       ) do
    with {:ok, prompt_doc} <-
           PromptDocument.ensure_exists(client, repo, publication_uri, created_at),
         {:ok, structure_doc} <-
           PromptDocument.ensure_structure_exists(client, repo, publication_uri, created_at) do
      create_full_response_document(
        invocation,
        result,
        client,
        repo,
        publication_uri,
        created_at,
        prompt_doc,
        structure_doc,
        settings
      )
    else
      {:error, reason} ->
        fail_standard_site(invocation, "site.standard.document", reason)
    end
  end

  defp create_full_response_document(
         invocation,
         result,
         client,
         repo,
         publication_uri,
         created_at,
         prompt_doc,
         structure_doc,
         settings
       ) do
    content = full_response_content(invocation, result, prompt_doc, structure_doc, settings)

    case Document.create(client, repo, publication_uri, content, created_at) do
      {:ok, doc_result} ->
        {:ok, doc_result}

      {:error, reason} ->
        fail_standard_site(invocation, "site.standard.document", reason)
    end
  end

  defp full_response_content(invocation, result, prompt_doc, structure_doc, settings) do
    request = Map.get(result, :messages) || invocation.anthropic_messages || %{}

    projection =
      Request.public_projection(request, %{
        anthropic_api_version: settings.anthropic_api_version,
        research_max_tokens: settings.anthropic_research_max_tokens
      })

    subject = PageCopy.subject(invocation, settings)

    %{
      full_response: result.full_response,
      selected_reply: Map.get(result, :compact_source, result.text),
      invocation_uri: invocation.invocation_uri,
      asked_text: subject.asked_text,
      parent_uri: subject.parent_uri,
      invoker_handle: subject.invoker_handle,
      parent_handle: subject.parent_handle,
      document_title: Map.get(result, :document_title),
      prompt: %{
        id: Request.system_prompt_id(),
        semantic_version: Request.system_prompt_semantic_version(),
        sha256: Request.system_prompt_sha256(),
        reader_url: prompt_doc.reader_url
      },
      structure_prompt: %{
        id: Request.structure_prompt_id(),
        semantic_version: Request.structure_prompt_semantic_version(),
        sha256: Request.structure_prompt_sha256(),
        reader_url: structure_doc.reader_url
      },
      parameters: projection.parameters
    }
  end

  defp fail_standard_site(invocation, collection, reason) do
    Operations.log_standard_site(invocation, collection: collection, reason: reason)
    {:error, standard_site_failure_detail(collection, reason)}
  end

  defp fail_document_create(invocation, result, document_error, completed_at, token) do
    fail_research(invocation, :standard_site_document_failed, completed_at, token, %{
      anthropic_messages: result.messages,
      anthropic_usage: result.usage,
      full_response: Map.get(result, :full_response),
      selected_reply: result.text,
      reply_validation: Map.get(result, :validation),
      failure_detail: document_error
    })
  end

  defp standard_site_failure_detail(collection, reason) do
    fields = Client.error_fields(reason)

    %{
      "reason" => "standard_site_document_failed",
      "collection" => collection
    }
    |> maybe_put_failure_field("status", fields[:status_code])
    |> maybe_put_failure_field("error", fields[:atproto_error] || fields[:failure_reason])
    |> maybe_put_failure_field("message", fields[:message])
  end

  defp maybe_put_failure_field(detail, _key, nil), do: detail
  defp maybe_put_failure_field(detail, key, value), do: Map.put(detail, key, value)

  defp document_uri({:ok, %{uri: uri}}), do: uri
  defp document_uri(_document), do: nil

  defp document_rkey({:ok, %{rkey: rkey}}), do: rkey
  defp document_rkey(_document), do: nil

  defp document_reader_url({:ok, %{reader_url: reader_url}})
       when is_binary(reader_url) and reader_url != "",
       do: reader_url

  defp document_reader_url(_document), do: nil

  defp defer_budget(invocation, defer_until, kind, token, dependencies) do
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
      {:ok, deferred} ->
        dependencies.limit_notice.maybe_post_budget(deferred, dependencies)
        :ok

      {:error, :stale_claim} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp fail_research(invocation, reason, completed_at, token, extra \\ %{}) do
    attrs =
      extra
      |> Map.merge(%{
        failure_category: failure_category(reason),
        failure_detail: Map.get(extra, :failure_detail, %{"reason" => safe_reason(reason)}),
        research_claim_token: nil,
        research_claimed_at: nil,
        completed_at: completed_at
      })

    case Store.transition_research(
           Repo.reload!(invocation),
           token,
           :failed,
           attrs,
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
  defp failure_category(:invalid_repair), do: :invalid_repair
  defp failure_category(_reason), do: :provider_response

  defp research_failure(invocation) do
    case Repo.reload!(invocation) do
      %Invocation{stage: :failed, failure_category: category} -> category
      _nonterminal_or_complete -> nil
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason({:provider_response, detail})
       when is_binary(detail) and detail != "",
       do: detail

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

  defp put_force_new_attempt(options, %Oban.Job{args: %{"new_attempt" => true}})
       when is_list(options),
       do: Keyword.put(options, :force_new_attempt, true)

  defp put_force_new_attempt(options, %Oban.Job{args: %{"new_attempt" => true}})
       when is_map(options),
       do: Map.put(options, :force_new_attempt, true)

  defp put_force_new_attempt(options, _job), do: options

  defp snooze_seconds(remaining_ms) when is_integer(remaining_ms) and remaining_ms <= 0, do: 1

  defp snooze_seconds(remaining_ms) when is_integer(remaining_ms) and remaining_ms > 0,
    do: div(remaining_ms + 999, 1_000)

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
      intent_builder: Keyword.get(config, :intent_builder, &Intent.build/6),
      now: Keyword.get(config, :now, &DateTime.utc_now/0),
      reply_job_builder: Keyword.get(config, :reply_job_builder, &reply_job/1),
      runner: Keyword.get(config, :runner, Runner),
      runner_options: Keyword.get(config, :runner_options, []),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings)),
      atproto_client: Keyword.get(config, :atproto_client, ContextBot.ATProto.ReqClient),
      limit_notice: Keyword.get(config, :limit_notice, LimitNotice),
      tid_generator: Keyword.get(config, :tid_generator, &TID.generate/1)
    }
  end
end
