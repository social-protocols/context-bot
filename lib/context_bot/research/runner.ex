defmodule ContextBot.Research.Runner do
  @moduledoc """
  Runs Anthropic research with durable budget exposure and raw-response ordering.

  Every POST is preceded by a committed reservation and sent marker. Every returned HTTP
  envelope is committed before decoding, pricing, or reply selection. Recovery always starts
  from the budget ledger rather than inferring attempt identity from response count.
  """

  import Ecto.Query

  require Logger

  alias ContextBot.ATProto.Client
  alias ContextBot.Repo

  alias ContextBot.Research.{
    AnthropicClient,
    Budget,
    BudgetEntry,
    Citations,
    InterruptRecovery,
    Pricing,
    Reply,
    Request,
    ResponseEnvelope
  }

  alias ContextBot.Thread.Media
  alias ContextBot.Workflow.{Invocation, Store}

  @http_date_regex ~r/^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), (?<day>\d{2}) (?<month>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (?<year>\d{4}) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) GMT$/

  @type result :: %{
          required(:messages) => map(),
          required(:text) => String.t(),
          optional(:full_response) => String.t(),
          optional(:document_title) => String.t(),
          optional(:disposition) => :reply | :no_reply,
          required(:usage) => map(),
          required(:validation) => map()
        }

  @spec run(Invocation.t(), keyword() | map()) ::
          {:ok, result()}
          | {:wait, pos_integer()}
          | {:deferred, DateTime.t(), BudgetEntry.kind()}
          | {:error, atom() | {atom(), term()}}
  def run(%Invocation{} = invocation, options) do
    config = config(options)
    invocation = Repo.reload!(invocation)

    with {:ok, invocation} <-
           config.store.renew_research_claim(invocation, config.claim_token, now(config)),
         {:ok, invocation, _request} <- ensure_request(invocation, config) do
      resume(invocation, config)
    end
  end

  defp resume(invocation, config) do
    invocation = Repo.reload!(invocation)
    timeout_ms = config.settings.anthropic_http_timeout_ms
    now = now(config)

    case InterruptRecovery.in_flight_attempt(invocation, now, timeout_ms) do
      {_entry, remaining} ->
        {:wait, remaining}

      nil ->
        with :ok <- mark_lost_unrecorded(invocation, config) do
          resume_attempt(invocation, latest_attempt(invocation), config)
        end
    end
  end

  defp mark_lost_unrecorded(invocation, config) do
    invocation
    |> Budget.unrecorded_exposed_attempts()
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case config.budget.mark_unrecorded_indeterminate(entry, now(config), config.claim_token) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, :stale_claim} -> {:halt, {:error, :stale_claim}}
      end
    end)
  end

  defp resume_attempt(invocation, nil, config),
    do: start_attempt(invocation, :research, config)

  defp resume_attempt(invocation, %BudgetEntry{state: :reserved} = entry, config) do
    case config.budget.reconcile_attempt(entry, now(config), config.claim_token) do
      {:reuse, reusable} -> send_attempt(invocation, reusable, config)
      {:error, :stale_claim} -> {:error, :stale_claim}
      _unexpected -> {:error, :invalid_attempt_state}
    end
  end

  defp resume_attempt(invocation, %BudgetEntry{} = entry, %{force_new_attempt: true} = config) do
    case stored_response(invocation, entry.attempt_key, config) do
      nil -> resume_recorded_or_replace(invocation, entry, config)
      _recorded -> start_forced_new_attempt(invocation, entry, config)
    end
  end

  defp resume_attempt(invocation, %BudgetEntry{} = entry, config) do
    resume_recorded_or_replace(invocation, entry, config)
  end

  defp resume_recorded_or_replace(
         invocation,
         %BudgetEntry{state: state} = entry,
         config
       )
       when state in [:sent, :indeterminate] do
    case stored_response(invocation, entry.attempt_key, config) do
      nil -> start_replacement_attempt(invocation, entry, config)
      response -> process_recorded(invocation, entry, response, config)
    end
  end

  defp resume_recorded_or_replace(invocation, %BudgetEntry{} = entry, config) do
    case stored_response(invocation, entry.attempt_key, config) do
      nil -> {:error, :invalid_attempt_state}
      response -> process_recorded(invocation, entry, response, config)
    end
  end

  defp start_forced_new_attempt(invocation, entry, config) do
    Logger.info(
      "context_bot_interrupt_recovery",
      Map.to_list(%{
        invocation_id: invocation.id,
        action: :new_attempt,
        remaining_ms: 0,
        attempt_kind: entry.kind
      })
    )

    start_attempt(Repo.reload!(invocation), :retry, config)
  end

  defp start_replacement_attempt(invocation, entry, config) do
    with {:ok, _lost} <- mark_lost_attempt(entry, config) do
      Logger.info(
        "context_bot_interrupt_recovery",
        Map.to_list(%{
          invocation_id: invocation.id,
          action: :new_attempt,
          remaining_ms: 0,
          attempt_kind: entry.kind
        })
      )

      start_attempt(Repo.reload!(invocation), :retry, config)
    end
  end

  defp mark_lost_attempt(%BudgetEntry{state: :indeterminate}, _config), do: {:ok, :already_lost}

  defp mark_lost_attempt(%BudgetEntry{} = entry, config) do
    config.budget.mark_unrecorded_indeterminate(entry, now(config), config.claim_token)
  end

  defp start_attempt(invocation, kind, config) do
    required_bytes = config.settings.max_response_bytes + ResponseEnvelope.max_overhead_bytes()

    if config.store.provider_response_storage_available?(
         invocation,
         required_bytes,
         config.storage_limit
       ) do
      reserve_attempt(invocation, kind, config)
    else
      {:error, :provider_storage_limit}
    end
  end

  defp reserve_attempt(invocation, kind, config) do
    amount = reservation(config.settings, kind)

    case config.budget.reserve_next(
           invocation,
           kind,
           now(config),
           amount,
           config.settings.anthropic_daily_budget_microdollars,
           config.claim_token
         ) do
      {:ok, entry} ->
        with :ok <- crash(config, :after_reservation, entry) do
          send_attempt(Repo.reload!(invocation), entry, config)
        end

      {:error, :daily_budget_exhausted} ->
        {:deferred, next_utc_rollover(now(config)), kind}

      {:error, :stale_claim} ->
        {:error, :stale_claim}
    end
  end

  defp send_attempt(invocation, entry, config) do
    request = request_for_entry(invocation, entry, config)

    with {:ok, sent} <- config.budget.mark_sent(entry, now(config), config.claim_token),
         :ok <- crash(config, :after_sent, sent),
         {:ok, _current_claim} <-
           config.store.renew_research_claim(invocation, config.claim_token, now(config)) do
      case config.client.send_message(request, metadata(sent)) do
        {:ok, envelope} -> persist_envelope(invocation, sent, envelope, config)
        {:error, reason} -> handle_transport_error(invocation, sent, reason, config)
      end
    end
  end

  defp persist_envelope(invocation, sent, envelope, config) do
    with :ok <- crash(config, :after_http, envelope),
         {:ok, response, recorded} <-
           config.store.record_anthropic_response(
             invocation,
             sent,
             envelope,
             config.storage_limit,
             now(config),
             config.claim_token
           ),
         :ok <- crash(config, :after_persistence, recorded) do
      process_recorded(Repo.reload!(invocation), recorded, response, config)
    end
  end

  defp handle_transport_error(invocation, sent, reason, config) do
    fields = Client.error_fields(reason)

    Logger.warning(
      "context_bot_interrupt_recovery",
      Map.to_list(%{
        invocation_id: invocation.id,
        action: :wait_for_timeout,
        remaining_ms: 0,
        failure_reason: fields[:failure_reason],
        status_code: fields[:status_code]
      })
    )

    with {:ok, _indeterminate} <-
           config.budget.mark_indeterminate(sent, now(config), config.claim_token) do
      {:error, :interrupted_after_send}
    end
  end

  defp process_recorded(invocation, entry, response, config) when is_map(response) do
    status = response_value(response, :status)

    if status in 200..299 do
      with {:ok, decoded} <- decode(config, response_value(response, :raw_body)) do
        classify_success(invocation, entry, decoded, config)
      end
    else
      classify_http_error(status, invocation, entry, response, config)
    end
  end

  defp classify_success(invocation, entry, decoded, config) do
    with {:ok, usage} <- response_usage(decoded),
         {:ok, settled} <-
           config.budget.settle(
             entry,
             usage,
             config.pricing,
             now(config),
             config.claim_token
           ),
         :ok <- safely_settled(settled),
         :ok <- crash(config, :after_settlement, settled),
         {:ok, invocation} <- checkpoint_usage(invocation, config) do
      classify_stop_reason(invocation, settled, decoded, config)
    end
  end

  defp classify_http_error(status, _invocation, entry, _response, config)
       when status in [401, 403] do
    with {:ok, _retained} <- retain_reservation(entry, config) do
      {:error, :provider_auth}
    end
  end

  defp classify_http_error(status, invocation, entry, response, config)
       when status == 429 or status >= 500 do
    with {:ok, _retained} <- retain_reservation(entry, config) do
      retry_http(invocation, response, config)
    end
  end

  defp classify_http_error(status, _invocation, entry, response, config)
       when status in 400..499 do
    with {:ok, _retained} <- retain_reservation(entry, config) do
      case provider_error_message(response) do
        message when is_binary(message) -> {:error, {:provider_response, message}}
        nil -> {:error, :provider_response}
      end
    end
  end

  defp classify_http_error(_status, _invocation, entry, _response, config) do
    with {:ok, _retained} <- retain_reservation(entry, config) do
      {:error, :provider_response}
    end
  end

  defp provider_error_message(response) do
    response
    |> response_value(:raw_body)
    |> decode_provider_error_message()
  end

  defp decode_provider_error_message(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, decoded} -> compact_provider_error_message(decoded)
      _invalid -> nil
    end
  end

  defp decode_provider_error_message(_body), do: nil

  defp compact_provider_error_message(%{"error" => %{"message" => message}})
       when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 240)
    end
  end

  defp compact_provider_error_message(_decoded), do: nil

  defp retry_http(invocation, response, config) do
    retry_count = recorded_retry_count(invocation)

    if retry_count < config.max_http_retries do
      delay =
        retry_delay_ms(
          retry_count + 1,
          retry_after_seconds(response_value(response, :headers), now(config)),
          config
        )

      config.sleep.(delay)
      start_attempt(Repo.reload!(invocation), :retry, config)
    else
      {:error, :provider_retries_exhausted}
    end
  end

  defp classify_stop_reason(invocation, %BudgetEntry{kind: :repair}, decoded, config) do
    classify_title_rewrite(invocation, decoded, config)
  end

  defp classify_stop_reason(invocation, %BudgetEntry{kind: :retry}, decoded, config) do
    if title_rewrite_pending?(invocation, config) and Reply.title_only_response?(decoded) do
      classify_title_rewrite(invocation, decoded, config)
    else
      classify_research_stop_reason(invocation, decoded, config)
    end
  end

  defp classify_stop_reason(invocation, _entry, decoded, config) do
    classify_research_stop_reason(invocation, decoded, config)
  end

  defp classify_research_stop_reason(
         %Invocation{} = invocation,
         %{"stop_reason" => stop_reason} = decoded,
         config
       )
       when stop_reason in ["pause_turn", :pause_turn] do
    if repair_request?(invocation) or structure_request?(invocation) do
      {:error, :pause_turn}
    else
      continue_pause(invocation, decoded, config)
    end
  end

  defp classify_research_stop_reason(invocation, decoded, config) do
    if structure_request?(invocation) do
      classify_structure(invocation, decoded, config)
    else
      classify_research(invocation, decoded, config)
    end
  end

  defp classify_research(invocation, decoded, config) do
    with {:ok, extracted} <- extract_research_writeup(decoded, invocation),
         writeup = Citations.publishable_writeup(extracted.text, extracted.citations),
         {:ok, checkpoint} <-
           persist_research_phase(invocation, writeup, extracted.citations, config) do
      start_attempt(checkpoint, :structure, config)
    end
  end

  defp classify_structure(invocation, decoded, config) do
    case select_reply(decoded, invocation) do
      {:ok, selected} ->
        {:ok, finish_selected(invocation, selected, config)}

      {:title_rewrite, _selected} ->
        start_attempt(Repo.reload!(invocation), :repair, config)

      {:repairable, text, _reasons} ->
        split_over_limit(invocation, text, decoded, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_title_rewrite(invocation, decoded, config) do
    with {:ok, title} <- Reply.select_title(decoded),
         {:title_rewrite, selected} <- latest_research_selection(invocation, config) do
      titled = %{
        selected
        | document_title: title,
          full_response: writeup_from(invocation, selected)
      }

      case Reply.classify_selected(titled) do
        {:ok, selected} ->
          {:ok, finish_selected(invocation, selected, config)}

        {:repairable, text, _reasons} ->
          split_over_limit(invocation, text, decoded, config, titled)
      end
    else
      _failed ->
        {:error, :invalid_structured_output}
    end
  end

  defp extract_research_writeup(%{"content" => content, "stop_reason" => stop_reason}, invocation) do
    with {:ok, tool_context} <- Reply.server_tool_context(research_messages(invocation)) do
      Reply.select_writeup(content, Map.put(tool_context, :stop_reason, stop_reason))
    end
  end

  defp extract_research_writeup(_decoded, _invocation), do: {:error, :malformed_provider_response}

  defp research_messages(%Invocation{anthropic_messages: request} = invocation) do
    if structure_request?(invocation) do
      %{"messages" => []}
    else
      request || %{"messages" => []}
    end
  end

  defp persist_research_phase(invocation, writeup, citations, config) do
    with {:ok, canonical} <- canonical_snapshot(invocation) do
      request =
        Request.structure(%{
          model_id: structure_model_id(config.settings),
          max_tokens: structure_max_tokens(config.settings),
          writeup: writeup,
          citations: citations,
          canonical_thread: canonical_text(canonical)
        })

      persist_request_checkpoint(invocation, request, config, %{
        full_response: writeup,
        citation_sources: citations
      })
    end
  end

  defp canonical_text(%{"text" => text}) when is_binary(text), do: text

  defp structure_request?(%Invocation{anthropic_messages: request}) when is_map(request),
    do: Request.structure_request?(request)

  defp structure_request?(_invocation), do: false

  defp structure_model_id(settings) do
    Map.get(settings, :anthropic_structure_model_id) || settings.anthropic_model_id
  end

  defp structure_max_tokens(settings) do
    Map.get(settings, :anthropic_structure_max_tokens) ||
      settings.anthropic_length_repair_max_tokens
  end

  defp finish_selected(invocation, %{disposition: :no_reply}, config) do
    %{
      messages: invocation.anthropic_messages,
      text: "",
      disposition: :no_reply,
      usage: usage_evidence(invocation, config),
      validation: %{"result" => "no_reply", "repair_used" => false, "phase" => "structure"}
    }
  end

  defp finish_selected(invocation, selected, config) do
    %{
      messages: invocation.anthropic_messages,
      text: selected.text,
      full_response: writeup_from(invocation, selected),
      document_title: selected.document_title,
      disposition: Map.get(selected, :disposition, :reply),
      usage: usage_evidence(invocation, config),
      validation: %{"result" => "valid", "repair_used" => false, "phase" => "structure"}
    }
    |> attach_full_response(invocation)
    |> attach_document_title(invocation)
  end

  defp writeup_from(%Invocation{full_response: writeup}, _selected)
       when is_binary(writeup) and writeup != "",
       do: writeup

  defp writeup_from(_invocation, %{full_response: writeup})
       when is_binary(writeup) and writeup != "",
       do: writeup

  defp writeup_from(_invocation, _selected), do: ""

  defp split_over_limit(invocation, text, decoded, config, selected \\ nil) do
    case Reply.split_text(text) do
      {:ok, part1, part2} ->
        {:ok,
         %{
           messages: invocation.anthropic_messages,
           text: part1,
           text_part2: part2,
           compact_source: text,
           usage: usage_evidence(invocation, config),
           validation: %{
             "result" => "split",
             "repair_used" => false,
             "part1_graphemes" => String.length(part1),
             "part2_graphemes" => String.length(part2)
           }
         }
         |> put_selected_fields(selected)
         |> attach_full_response(invocation, decoded)
         |> attach_document_title(invocation, decoded)}

      :error ->
        {:error, :invalid_repair}
    end
  end

  defp put_selected_fields(result, %{full_response: full, document_title: title})
       when is_binary(full) and is_binary(title) do
    result
    |> Map.put(:full_response, full)
    |> Map.put(:document_title, title)
  end

  defp put_selected_fields(result, _selected), do: result

  defp continue_pause(invocation, %{"content" => content}, config) when is_list(content) do
    if continuation_count(invocation, config) > config.settings.max_tool_continuations do
      {:error, :continuation_limit_exceeded}
    else
      with {:ok, _tool_context} <-
             Reply.server_tool_context(invocation.anthropic_messages, content),
           request = continuation_request(invocation.anthropic_messages, content, config.settings),
           {:ok, checkpoint} <- checkpoint_request(invocation, request, config) do
        start_attempt(checkpoint, :continuation, config)
      end
    end
  end

  defp continue_pause(_invocation, _decoded, _config),
    do: {:error, :malformed_provider_response}

  defp checkpoint_request(invocation, request, config) do
    with :ok <- crash(config, :before_request_checkpoint, request) do
      persist_request_checkpoint(invocation, request, config)
    end
  end

  defp persist_request_checkpoint(invocation, request, config, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          anthropic_messages: request,
          anthropic_usage: usage_evidence(invocation, config)
        },
        extra
      )

    case config.store.transition_research(
           invocation,
           config.claim_token,
           :researching,
           attrs,
           nil,
           now(config)
         ) do
      {:ok, checkpoint} ->
        with :ok <- crash(config, :after_checkpoint, checkpoint), do: {:ok, checkpoint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continuation_request(%{"messages" => messages} = request, content, settings) do
    case List.last(messages) do
      %{"role" => "assistant", "content" => ^content} ->
        request

      _not_checkpointed ->
        Request.continue(request, content, settings.anthropic_research_max_tokens)
    end
  end

  defp ensure_request(%Invocation{anthropic_messages: request} = invocation, _config)
       when is_map(request),
       do: {:ok, invocation, request}

  defp ensure_request(%Invocation{} = invocation, config) do
    with {:ok, canonical} <- canonical_snapshot(invocation) do
      request =
        Request.initial(canonical, %{
          model_id: config.settings.anthropic_model_id,
          effort: config.settings.anthropic_effort,
          max_tokens: config.settings.anthropic_research_max_tokens,
          max_web_search_uses: config.settings.max_web_search_uses,
          max_web_fetch_uses: config.settings.max_web_fetch_uses,
          max_web_fetch_content_tokens: config.settings.max_web_fetch_content_tokens,
          web_search_tool_type: config.settings.anthropic_web_search_tool_type,
          web_fetch_tool_type: config.settings.anthropic_web_fetch_tool_type
        })

      case config.store.transition_research(
             invocation,
             config.claim_token,
             :researching,
             %{anthropic_messages: request},
             nil,
             now(config)
           ) do
        {:ok, persisted} -> {:ok, persisted, persisted.anthropic_messages}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp canonical_snapshot(%Invocation{
         canonical_thread_version: "1",
         canonical_thread: text
       })
       when is_binary(text) and text != "",
       do: {:ok, %{"version" => 1, "text" => text}}

  defp canonical_snapshot(%Invocation{
         canonical_thread_version: "2",
         canonical_thread: text,
         canonical_media: media
       })
       when is_binary(text) and text != "" and is_list(media) do
    if Media.validate(media) == :ok do
      {:ok, %{"version" => 2, "text" => text, "media" => media}}
    else
      {:error, :invalid_canonical_thread}
    end
  end

  defp canonical_snapshot(_invocation), do: {:error, :invalid_canonical_thread}

  defp latest_attempt(invocation) do
    BudgetEntry
    |> where([entry], entry.invocation_id == ^invocation.id)
    |> order_by([entry], desc: entry.id)
    |> limit(1)
    |> Repo.one()
  end

  defp stored_response(invocation, attempt_key, config) do
    Enum.find(
      config.store.anthropic_responses(invocation),
      &(response_value(&1, :attempt_key) == attempt_key)
    )
  end

  defp recorded_retry_count(invocation) do
    BudgetEntry
    |> where(
      [entry],
      entry.invocation_id == ^invocation.id and entry.kind == :retry and
        not is_nil(entry.response_recorded_at)
    )
    |> Repo.aggregate(:count)
  end

  defp decode(config, raw_body) when is_binary(raw_body) do
    case config.decoder.(raw_body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :malformed_provider_response}
    end
  end

  defp decode(_config, _raw_body), do: {:error, :malformed_provider_response}

  defp response_usage(%{"usage" => usage}) when is_map(usage), do: {:ok, usage}
  defp response_usage(_response), do: {:error, :unsafe_provider_usage}

  defp safely_settled(%{state: :settled}), do: :ok
  defp safely_settled(_entry), do: {:error, :unsafe_provider_usage}

  defp checkpoint_usage(invocation, config) do
    case config.store.transition_research(
           invocation,
           config.claim_token,
           :researching,
           %{anthropic_usage: usage_evidence(invocation, config)},
           nil,
           now(config)
         ) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_full_response(result, invocation, decoded \\ nil)

  defp attach_full_response(%{full_response: full} = result, _invocation, _decoded)
       when is_binary(full) and byte_size(full) > 0,
       do: result

  defp attach_full_response(result, %Invocation{full_response: writeup}, _decoded)
       when is_binary(writeup) and byte_size(writeup) > 0 do
    Map.put(result, :full_response, writeup)
  end

  defp attach_full_response(result, invocation, decoded) do
    case current_or_stored_field(invocation, decoded, &Reply.full_response_from_messages/1) do
      full when is_binary(full) and byte_size(full) > 0 ->
        Map.put(result, :full_response, full)

      _missing ->
        result
    end
  end

  defp attach_document_title(result, invocation, decoded \\ nil)

  defp attach_document_title(%{document_title: title} = result, _invocation, _decoded)
       when is_binary(title) and byte_size(title) > 0,
       do: result

  defp attach_document_title(result, invocation, decoded) do
    case current_or_stored_field(invocation, decoded, &Reply.document_title_from_messages/1) do
      title when is_binary(title) and byte_size(title) > 0 ->
        Map.put(result, :document_title, title)

      _missing ->
        result
    end
  end

  defp current_or_stored_field(invocation, decoded, extractor) do
    extractor.(from_current_envelope(decoded)) || extractor.(invocation.anthropic_messages)
  end

  defp from_current_envelope(%{"content" => content}) when is_list(content) do
    %{"messages" => [%{"role" => "assistant", "content" => content}]}
  end

  defp from_current_envelope(_decoded), do: nil

  defp select_reply(%{"content" => content, "stop_reason" => stop_reason}, invocation) do
    with {:ok, tool_context} <- Reply.server_tool_context(invocation.anthropic_messages) do
      Reply.select(content, Map.put(tool_context, :stop_reason, stop_reason))
    end
  end

  defp select_reply(_response, _invocation), do: {:error, :malformed_provider_response}

  defp request_for_entry(invocation, %BudgetEntry{kind: :repair}, config),
    do: title_rewrite_request(invocation, config)

  defp request_for_entry(invocation, %BudgetEntry{kind: :retry}, config) do
    if title_rewrite_pending?(invocation, config) do
      title_rewrite_request(invocation, config)
    else
      invocation.anthropic_messages
    end
  end

  defp request_for_entry(invocation, _entry, _config), do: invocation.anthropic_messages

  defp title_rewrite_pending?(invocation, config),
    do: match?({:title_rewrite, _selected}, latest_research_selection(invocation, config))

  defp title_rewrite_request(invocation, config) do
    {:title_rewrite, selected} = latest_research_selection(invocation, config)

    Request.title_rewrite(%{
      model_id: config.settings.anthropic_title_model_id,
      max_tokens: config.settings.anthropic_length_repair_max_tokens,
      invocation_text: invocation_text(invocation),
      compact_reply: selected.text,
      full_response: writeup_from(invocation, selected)
    })
  end

  defp invocation_text(%Invocation{invocation_text: text})
       when is_binary(text) and text != "",
       do: text

  defp invocation_text(%Invocation{canonical_thread: text})
       when is_binary(text) and text != "",
       do: text

  defp invocation_text(_invocation), do: ""

  defp latest_research_selection(invocation, config) do
    invocation
    |> config.store.anthropic_responses()
    |> Enum.reverse()
    |> Enum.find_value(:error, &research_selection_from(invocation, config, &1))
  end

  defp research_selection_from(invocation, config, response) do
    response
    |> successful_body(config)
    |> select_successful_research(invocation)
  end

  defp successful_body(response, config) do
    status = response_value(response, :status)

    if status in 200..299 do
      decode(config, response_value(response, :raw_body))
    else
      :error
    end
  end

  defp select_successful_research({:ok, decoded}, invocation) do
    case select_reply(decoded, invocation) do
      {:error, _reason} -> nil
      result -> result
    end
  end

  defp select_successful_research(_invalid, _invocation), do: nil

  defp retain_reservation(entry, config),
    do:
      config.budget.settle(
        entry,
        %{},
        config.pricing,
        now(config),
        config.claim_token
      )

  defp usage_evidence(invocation, config) do
    responses = config.store.anthropic_responses(invocation)
    decoded = decoded_responses(responses)

    attempts =
      Enum.flat_map(decoded, fn {response, body} ->
        case body do
          %{"usage" => usage} when is_map(usage) ->
            [
              %{
                "attempt_key" => response_value(response, :attempt_key),
                "kind" => response_value(response, :kind) |> kind_string(),
                "usage" => usage
              }
            ]

          _missing ->
            []
        end
      end)

    tool_counts = tool_use_counts(decoded)

    %{
      "attempts" => attempts,
      "continuations" => continuation_count(decoded),
      "response_count" => length(responses),
      "tool_use_counts" => tool_counts,
      "tool_uses" => Enum.sum(Map.values(tool_counts)),
      "totals" => Enum.reduce(attempts, %{}, &merge_attempt_usage/2)
    }
  end

  defp merge_attempt_usage(%{"usage" => usage}, totals), do: merge_counts(totals, usage)

  defp merge_counts(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      case {left_value, right_value} do
        {left_count, right_count} when is_integer(left_count) and is_integer(right_count) ->
          left_count + right_count

        {%{} = left_map, %{} = right_map} ->
          merge_counts(left_map, right_map)

        {_left, right_value} ->
          right_value
      end
    end)
  end

  defp decoded_responses(responses) when is_list(responses) do
    Enum.flat_map(responses, fn response ->
      case Jason.decode(response_value(response, :raw_body)) do
        {:ok, body} when is_map(body) -> [{response, body}]
        _invalid -> []
      end
    end)
  end

  defp continuation_count(%Invocation{} = invocation, config) do
    responses = config.store.anthropic_responses(invocation)
    responses |> decoded_responses() |> continuation_count()
  end

  defp continuation_count(decoded_responses) when is_list(decoded_responses) do
    Enum.count(decoded_responses, fn {_response, body} ->
      body["stop_reason"] in ["pause_turn", :pause_turn]
    end)
  end

  defp tool_use_counts(decoded_responses) do
    Enum.reduce(
      decoded_responses,
      %{"web_fetch" => 0, "web_search" => 0},
      fn {_response, body}, counts -> count_response_tools(body, counts) end
    )
  end

  defp count_response_tools(%{"content" => content}, counts) when is_list(content) do
    Enum.reduce(content, counts, fn
      %{"type" => "server_tool_use", "name" => name}, counts
      when name in ["web_search", "web_fetch"] ->
        Map.update!(counts, name, &(&1 + 1))

      _block, counts ->
        counts
    end)
  end

  defp count_response_tools(_body, counts), do: counts

  defp repair_request?(%Invocation{anthropic_messages: %{"messages" => messages}}) do
    case List.last(messages) do
      %{"role" => "user", "content" => "LENGTH_REPAIR\n" <> _rest} -> true
      _other -> false
    end
  end

  defp repair_request?(_invocation), do: false

  defp metadata(entry), do: %{attempt_key: entry.attempt_key, kind: entry.kind}

  defp response_value(response, key),
    do: Map.get(response, key, Map.get(response, Atom.to_string(key)))

  defp kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_string(kind), do: kind

  defp retry_after_seconds(headers, now) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      [value | _rest] when is_binary(value) -> parse_retry_after(value, now)
      value when is_binary(value) -> parse_retry_after(value, now)
      _missing -> nil
    end
  end

  defp retry_after_seconds(_headers, _now), do: nil

  defp parse_retry_after(value, now) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _not_delta_seconds -> parse_retry_after_date(value, now)
    end
  end

  defp parse_retry_after_date(value, now) do
    with %{} = parts <- Regex.named_captures(@http_date_regex, value),
         {:ok, month} <- http_month(parts["month"]),
         {:ok, date} <-
           Date.new(component(parts["year"]), month, component(parts["day"])),
         {:ok, time} <-
           Time.new(
             component(parts["hour"]),
             component(parts["minute"]),
             component(parts["second"])
           ),
         {:ok, retry_at} <- DateTime.new(date, time, "Etc/UTC") do
      retry_at
      |> DateTime.diff(DateTime.shift_zone!(now, "Etc/UTC"), :microsecond)
      |> max(0)
      |> ceil_seconds()
    else
      _invalid -> nil
    end
  end

  defp component(value), do: String.to_integer(value)

  defp http_month("Jan"), do: {:ok, 1}
  defp http_month("Feb"), do: {:ok, 2}
  defp http_month("Mar"), do: {:ok, 3}
  defp http_month("Apr"), do: {:ok, 4}
  defp http_month("May"), do: {:ok, 5}
  defp http_month("Jun"), do: {:ok, 6}
  defp http_month("Jul"), do: {:ok, 7}
  defp http_month("Aug"), do: {:ok, 8}
  defp http_month("Sep"), do: {:ok, 9}
  defp http_month("Oct"), do: {:ok, 10}
  defp http_month("Nov"), do: {:ok, 11}
  defp http_month("Dec"), do: {:ok, 12}
  defp http_month(_invalid), do: :error

  defp ceil_seconds(0), do: 0
  defp ceil_seconds(microseconds), do: div(microseconds + 999_999, 1_000_000)

  defp retry_delay_ms(_attempt, seconds, config) when is_integer(seconds),
    do: min(seconds * 1_000, config.retry_max_ms)

  defp retry_delay_ms(attempt, nil, config) do
    exponent = max(attempt - 1, 0)
    min(config.retry_base_ms * Integer.pow(2, exponent), config.retry_max_ms)
  end

  defp reservation(settings, :research),
    do: settings.anthropic_research_reservation_microdollars

  defp reservation(settings, :continuation),
    do: settings.anthropic_continuation_reservation_microdollars

  defp reservation(settings, :repair),
    do: settings.anthropic_repair_reservation_microdollars

  defp reservation(settings, :structure) do
    Map.get(settings, :anthropic_structure_reservation_microdollars) ||
      settings.anthropic_repair_reservation_microdollars
  end

  defp reservation(settings, :retry), do: settings.anthropic_retry_reservation_microdollars

  defp next_utc_rollover(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
  end

  defp now(%{now: now}) when is_function(now, 0), do: now.()
  defp crash(%{crash: crash}, point, value), do: crash.(point, value)

  defp config(options) do
    options = if is_map(options), do: Map.to_list(options), else: options
    settings = Keyword.fetch!(options, :settings)

    %{
      budget: Keyword.get(options, :budget, Budget),
      claim_token: Keyword.fetch!(options, :claim_token),
      client: Keyword.get(options, :client, AnthropicClient),
      crash: Keyword.get(options, :crash, fn _point, _value -> :ok end),
      decoder: Keyword.get(options, :decoder, &Jason.decode/1),
      force_new_attempt: Keyword.get(options, :force_new_attempt, false),
      max_http_retries: settings.anthropic_max_http_retries,
      now: Keyword.get(options, :now, &DateTime.utc_now/0),
      pricing: Pricing.fetch!(settings.anthropic_pricing_version),
      retry_base_ms: settings.anthropic_retry_base_ms,
      retry_max_ms: settings.anthropic_retry_max_ms,
      settings: settings,
      sleep: Keyword.get(options, :sleep, &Process.sleep/1),
      storage_limit: Keyword.get(options, :max_storage_bytes, settings.max_storage_bytes),
      store: Keyword.get(options, :store, Store)
    }
  end
end
