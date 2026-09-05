defmodule ContextBot.Workflow.Store do
  @moduledoc """
  Short SQLite transactions for durable receipt insertion and workflow handoffs.

  Callers perform all external I/O before or after these operations.
  """

  # Ecto.Multi embeds MapSet's opaque representation; Ecto's transaction layer uses the same
  # Dialyzer annotation at this boundary.
  @dialyzer :no_opaque

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{BudgetEntry, ResponseEnvelope}
  alias ContextBot.Workflow.{Failure, Invocation}
  alias Ecto.{Changeset, Multi}

  @terminal_statuses [:ineligible, :complete, :failed]
  @terminal_dry_run_stages [:complete, :failed, :ineligible]
  @maximum_dry_run_question_bytes 10_000
  @question_target_uri "local://context-bot/question"

  @doc "Creates or attaches to one matching nonterminal local invocation atomically."
  @spec create_or_attach_dry_run(
          String.t(),
          String.t(),
          DateTime.t(),
          (String.t(), String.t() -> Ecto.Changeset.t())
        ) :: {:ok, Invocation.t(), :created | :attached} | {:error, :invalid_input}
  def create_or_attach_dry_run(target_uri, question, %DateTime{} = received_at, job_builder)
      when is_binary(target_uri) and is_function(job_builder, 2) do
    if valid_dry_run_input?(target_uri, question) do
      create_or_attach_valid_dry_run(target_uri, question, received_at, job_builder)
    else
      {:error, :invalid_input}
    end
  end

  def create_or_attach_dry_run(_target_uri, _question, _received_at, _job_builder),
    do: {:error, :invalid_input}

  @doc "Creates or attaches to one matching nonterminal local question-only invocation atomically."
  @spec create_or_attach_question_dry_run(
          String.t(),
          map(),
          DateTime.t(),
          (String.t(), String.t() -> Ecto.Changeset.t())
        ) :: {:ok, Invocation.t(), :created | :attached} | {:error, :invalid_input}
  def create_or_attach_question_dry_run(
        question,
        canonical,
        %DateTime{} = received_at,
        job_builder
      )
      when is_binary(question) and is_map(canonical) and is_function(job_builder, 2) do
    if valid_question?(question) and valid_question_canonical?(canonical) do
      create_or_attach_valid_question_dry_run(question, canonical, received_at, job_builder)
    else
      {:error, :invalid_input}
    end
  end

  def create_or_attach_question_dry_run(_question, _canonical, _received_at, _job_builder),
    do: {:error, :invalid_input}

  @doc "Creates or attaches to one operator-selected public invocation atomically."
  @spec create_or_attach_live_run(map(), DateTime.t(), (String.t(), String.t() -> Changeset.t())) ::
          {:ok, Invocation.t(), :created | :attached | :complete | :terminal}
          | {:error, :active_invocation, %{id: pos_integer(), uri: String.t()}}
          | {:error, :contradictory_invocations, [pos_integer()]}
          | {:error, :invalid_input | Changeset.t()}
  def create_or_attach_live_run(receipt, %DateTime{} = received_at, job_builder)
      when is_map(receipt) and is_function(job_builder, 2) do
    if valid_live_run_receipt?(receipt) do
      create_or_attach_valid_live_run(receipt, received_at, job_builder)
    else
      {:error, :invalid_input}
    end
  end

  def create_or_attach_live_run(_receipt, _received_at, _job_builder),
    do: {:error, :invalid_input}

  @doc "Requeues a due operator live-demo budget deferral without admission checks."
  @spec resume_due_live_budget(
          Invocation.t(),
          DateTime.t(),
          (String.t(), String.t() -> Changeset.t())
        ) :: {:ok, Invocation.t(), :resumed | :unchanged} | {:error, Changeset.t()}
  def resume_due_live_budget(%Invocation{id: id}, %DateTime{} = now, job_builder)
      when is_integer(id) and is_function(job_builder, 2) do
    result =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, id)

          if due_live_budget?(invocation, now) do
            resume_live_budget!(invocation, job_builder)
          else
            {invocation, :unchanged}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, {invocation, disposition}} -> {:ok, invocation, disposition}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_due_live_budget(_invocation, _now, _job_builder), do: {:error, :invalid_input}

  @spec receive_mention(map(), DateTime.t(), Ecto.Changeset.t() | nil) ::
          {:ok, Invocation.t(), :inserted | :duplicate}
  def receive_mention(notification, received_at, next_job) do
    cid = fetch!(notification, :cid)
    initial_status = if next_job, do: :received, else: :deferred_capacity

    attrs = %{
      invocation_uri: fetch!(notification, :uri),
      notification_cid: cid,
      current_cid: cid,
      actor_did: fetch!(notification, :actor_did),
      actor_handle: fetch(notification, :actor_handle),
      raw_notification: fetch!(notification, :raw),
      received_at: received_at,
      status: initial_status,
      stage: initial_status
    }

    multi =
      Multi.new()
      |> Multi.run(:invocation, fn repo, _changes -> receive_once(repo, attrs) end)
      |> Multi.run(:next_job, fn repo, %{invocation: {_invocation, result}} ->
        maybe_insert_job(repo, result == :inserted, next_job)
      end)

    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{invocation: {invocation, result}}} -> {:ok, invocation, result}
      {:error, _operation, reason, _changes} -> raise_transaction_error(reason)
    end
  end

  @spec transition(Invocation.t(), atom(), atom(), map(), Ecto.Changeset.t() | nil) ::
          {:ok, Invocation.t()} | {:error, :stale_stage | Ecto.Changeset.t()}
  def transition(%Invocation{id: id}, from_stage, to_stage, attrs, next_job) do
    transition_attrs =
      attrs
      |> Map.drop([:status, "status", :stage, "stage"])
      |> Map.put(:status, to_stage)
      |> Map.put(:stage, to_stage)

    multi =
      Multi.new()
      |> Multi.run(:invocation, fn repo, _changes ->
        compare_and_update(repo, id, from_stage, transition_attrs)
      end)
      |> Multi.run(:next_job, fn repo, _changes -> maybe_insert_job(repo, true, next_job) end)

    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{invocation: invocation}} -> {:ok, invocation}
      {:error, _operation, :stale_stage, _changes} -> {:error, :stale_stage}
      {:error, _operation, %Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Claims the one-shot limit-notice slot without changing stage.

  Used for budget notices that must remain `deferred_budget`. Actor-rate notices
  claim the kind in the same `reply_ready` transition as the frozen intent.
  """
  @spec claim_limit_notice(Invocation.t(), :actor_rate | :budget) ::
          {:ok, Invocation.t()}
          | {:error, :already_claimed | :dry_run | :stale_stage | Changeset.t()}
  def claim_limit_notice(%Invocation{id: id, stage: stage} = invocation, kind)
      when kind in [:actor_rate, :budget] do
    if invocation.dry_run do
      {:error, :dry_run}
    else
      transact_limit_notice(fn -> claim_limit_notice!(id, stage, kind) end)
    end
  end

  @doc """
  Caches a Standard Reader index probe on the invocation row.

  A confirmed `:indexed` result latches `reader_ready_at`. `:not_indexed` and
  `:ambiguous` only refresh `reader_checked_at` so the public mirror can skip
  the AppView until the negative TTL expires. This never clears a ready latch.
  """
  @spec record_reader_index(Invocation.t(), :indexed | :not_indexed | :ambiguous, DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, Changeset.t()}
  def record_reader_index(%Invocation{id: id}, result, %DateTime{} = now)
      when result in [:indexed, :not_indexed, :ambiguous] do
    current = Repo.get!(Invocation, id)

    attrs =
      if result == :indexed do
        %{reader_checked_at: now, reader_ready_at: current.reader_ready_at || now}
      else
        %{reader_checked_at: now}
      end

    current
    |> Invocation.reader_index_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Persists follower-post coordinates on a complete invocation.

  This does not require a publication claim and does not change stage. It is
  the path used after thread replies are already published and the follower
  card is waiting on Standard Reader. An existing published follower URI is
  never overwritten.
  """
  @spec record_follower_post(Invocation.t(), map()) ::
          {:ok, Invocation.t()} | {:error, :already_published | :stale_stage | Changeset.t()}
  def record_follower_post(%Invocation{id: id}, attrs) when is_map(attrs) do
    result =
      Repo.transaction(
        fn ->
          current = Repo.get!(Invocation, id)

          cond do
            current.stage != :complete ->
              Repo.rollback(:stale_stage)

            follower_published?(current) ->
              Repo.rollback(:already_published)

            true ->
              persist_follower_post!(current, attrs)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Records the published limit-notice coordinates after a successful putRecord."
  @spec record_limit_notice(Invocation.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :stale_stage | Changeset.t()}
  def record_limit_notice(%Invocation{id: id, stage: stage}, uri, cid, %DateTime{} = posted_at)
      when is_binary(uri) and uri != "" and is_binary(cid) and cid != "" do
    transact_limit_notice(fn ->
      record_limit_notice!(id, stage, uri, cid, posted_at)
    end)
  end

  @doc """
  Fences a research checkpoint or terminal handoff by the currently persisted claim token.
  """
  @spec transition_research(
          Invocation.t(),
          String.t(),
          atom(),
          map(),
          Ecto.Changeset.t() | nil,
          DateTime.t()
        ) :: {:ok, Invocation.t()} | {:error, :stale_claim | Ecto.Changeset.t()}
  def transition_research(
        %Invocation{id: id},
        token,
        to_stage,
        attrs,
        next_job,
        %DateTime{} = now
      )
      when is_binary(token) and token != "" do
    transition_attrs = research_transition_attrs(attrs, token, to_stage, now)

    multi =
      Multi.new()
      |> Multi.run(:invocation, fn repo, _changes ->
        compare_and_update_research(repo, id, token, transition_attrs)
      end)
      |> Multi.run(:next_job, fn repo, _changes -> maybe_insert_job(repo, true, next_job) end)

    case Repo.transaction(multi, mode: :immediate) do
      {:ok, %{invocation: invocation}} -> {:ok, invocation}
      {:error, _operation, :stale_claim, _changes} -> {:error, :stale_claim}
      {:error, _operation, %Changeset{} = changeset, _changes} -> {:error, changeset}
    end
  end

  @doc "Renews the current research claim or returns a finite stale-claim result."
  @spec renew_research_claim(Invocation.t(), String.t(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :stale_claim}
  def renew_research_claim(%Invocation{id: id}, token, %DateTime{} = now)
      when is_binary(token) and token != "" do
    result =
      Repo.transaction(
        fn ->
          case research_claim_context(id) do
            %{stage: :researching, token: ^token, claimed_at: claimed_at} ->
              Invocation
              |> where([invocation], invocation.id == ^id)
              |> Repo.update_all(set: [research_claimed_at: latest_timestamp(claimed_at, now)])

              Repo.get!(Invocation, id)

            _stale ->
              Repo.rollback(:stale_claim)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, :stale_claim} -> {:error, :stale_claim}
    end
  end

  @doc """
  Atomically acquires or renews one research-worker lease while claiming an eligible stage.

  A stable token lets the same Oban job resume immediately after a crash. A different job may
  take over only after the bounded lease expires.
  """
  @spec claim_research(Invocation.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :busy | :stale_stage | Ecto.Changeset.t()}
  def claim_research(
        %Invocation{id: id},
        token,
        %DateTime{} = now,
        %DateTime{} = stale_before
      )
      when is_binary(token) and token != "" do
    result =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, id)

          if research_claimable?(invocation, token, now, stale_before) do
            persist_research_claim(invocation, token, now)
          else
            Repo.rollback(research_claim_error(invocation, now))
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Atomically acquires or renews one publication lease for the frozen reply intent.

  The same Oban job token resumes immediately. Another token may take over only after the current
  lease is stale.
  """
  @spec claim_publication(Invocation.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :busy | :stale_stage | Ecto.Changeset.t()}
  def claim_publication(
        %Invocation{id: id},
        token,
        %DateTime{} = now,
        %DateTime{} = stale_before
      )
      when is_binary(token) and token != "" do
    result =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, id)

          if publication_claimable?(invocation, token, stale_before) do
            persist_publication_claim(invocation, token, now)
          else
            Repo.rollback(publication_claim_error(invocation))
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Renews the exact current publication claim before external I/O."
  @spec renew_publication_claim(Invocation.t(), String.t(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :stale_claim}
  def renew_publication_claim(%Invocation{id: id}, token, %DateTime{} = now)
      when is_binary(token) and token != "" do
    result =
      Repo.transaction(
        fn ->
          case publication_claim_context(id) do
            %{stage: :publishing, token: ^token, claimed_at: claimed_at} ->
              Invocation
              |> where(
                [invocation],
                invocation.id == ^id and invocation.stage == :publishing and
                  invocation.publication_claim_token == ^token
              )
              |> Repo.update_all(set: [publication_claimed_at: latest_timestamp(claimed_at, now)])

              Repo.get!(Invocation, id)

            _stale ->
              Repo.rollback(:stale_claim)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, :stale_claim} -> {:error, :stale_claim}
    end
  end

  @doc "Fences a publication terminal transition by the exact persisted claim token."
  @spec transition_publication(Invocation.t(), String.t(), atom(), map(), DateTime.t()) ::
          {:ok, Invocation.t()} | {:error, :stale_claim | Ecto.Changeset.t()}
  def transition_publication(
        %Invocation{id: id},
        token,
        to_stage,
        attrs,
        %DateTime{} = completed_at
      )
      when is_binary(token) and token != "" and to_stage in [:complete, :failed] do
    transition_attrs =
      attrs
      |> Map.drop([
        :status,
        "status",
        :stage,
        "stage",
        :publication_claim_token,
        "publication_claim_token",
        :publication_claimed_at,
        "publication_claimed_at"
      ])
      |> Map.merge(%{
        status: to_stage,
        stage: to_stage,
        publication_claim_token: nil,
        publication_claimed_at: nil,
        completed_at: completed_at
      })

    result =
      Repo.transaction(
        fn ->
          case compare_and_update_publication(Repo, id, token, transition_attrs) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, :stale_claim} -> {:error, :stale_claim}
      {:error, %Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @spec append_anthropic_response(Invocation.t(), map(), pos_integer()) ::
          {:ok, Invocation.t()} | {:error, :provider_storage_limit | :stale_claim}
  def append_anthropic_response(%Invocation{id: id}, response, storage_limit)
      when is_map(response) and is_integer(storage_limit) and storage_limit > 0 do
    prepared = ResponseEnvelope.prepare(response)

    result =
      Repo.transaction(
        fn ->
          case research_claim_context(id) do
            %{stage: :researching} -> Repo.rollback(:stale_claim)
            _not_researching -> :ok
          end

          enforce_response_storage_limit!(id, prepared.storage_bytes, storage_limit)

          %ResponseEnvelope{}
          |> ResponseEnvelope.changeset(Map.put(prepared, :invocation_id, id))
          |> Repo.insert!()

          Repo.get!(Invocation, id)
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, :provider_storage_limit} -> {:error, :provider_storage_limit}
      {:error, :stale_claim} -> {:error, :stale_claim}
    end
  end

  @doc """
  Appends one complete tagged Anthropic envelope and records its matching budget response marker
  in the same short transaction.
  """
  @spec record_anthropic_response(
          Invocation.t(),
          BudgetEntry.t(),
          map(),
          pos_integer(),
          DateTime.t(),
          String.t()
        ) ::
          {:ok, map(), BudgetEntry.t()}
          | {:error, :provider_storage_limit | :invalid_attempt_state | :stale_claim}
  def record_anthropic_response(
        %Invocation{id: invocation_id},
        %BudgetEntry{id: entry_id} = entry_snapshot,
        response,
        storage_limit,
        %DateTime{} = recorded_at,
        token
      ) do
    prepared =
      ResponseEnvelope.prepare(response, %{
        attempt_key: entry_snapshot.attempt_key,
        kind: entry_snapshot.kind
      })

    result =
      Repo.transaction(
        fn ->
          authorize_research_claim!(invocation_id, token)
          entry = Repo.get!(BudgetEntry, entry_id)

          if entry.invocation_id != invocation_id or entry.state != :sent or
               entry.response_recorded_at != nil or entry.research_claim_token != token do
            Repo.rollback(:invalid_attempt_state)
          end

          enforce_response_storage_limit!(invocation_id, prepared.storage_bytes, storage_limit)

          stored =
            %ResponseEnvelope{}
            |> ResponseEnvelope.changeset(
              prepared
              |> Map.put(:invocation_id, invocation_id)
              |> Map.put(:budget_entry_id, entry_id)
            )
            |> Repo.insert!()

          entry =
            entry
            |> BudgetEntry.changeset(%{response_recorded_at: recorded_at})
            |> Repo.update!()

          renew_research_claim_at(invocation_id, token, recorded_at)
          {stored, entry}
        end,
        mode: :immediate
      )

    case result do
      {:ok, {stored, entry}} ->
        {:ok, ResponseEnvelope.to_map(stored), entry}

      {:error, reason} when reason in [:provider_storage_limit, :invalid_attempt_state] ->
        {:error, reason}

      {:error, :stale_claim} ->
        {:error, :stale_claim}
    end
  end

  @doc "Returns the complete provider envelope ledger in insertion order."
  @spec anthropic_responses(Invocation.t()) :: [map()]
  def anthropic_responses(%Invocation{id: id}) do
    legacy_responses(id) ++
      (ResponseEnvelope
       |> where([response], response.invocation_id == ^id)
       |> order_by([response], asc: response.id)
       |> Repo.all()
       |> Enum.map(&ResponseEnvelope.to_map/1))
  end

  @doc "Returns the actual SQLite bytes occupied by the invocation's provider-response ledger."
  @spec provider_response_storage_bytes(Invocation.t() | pos_integer()) :: non_neg_integer()
  def provider_response_storage_bytes(%Invocation{id: id}),
    do: provider_response_storage_bytes(id)

  def provider_response_storage_bytes(invocation_id)
      when is_integer(invocation_id) and invocation_id > 0 do
    legacy_storage_bytes(invocation_id) + response_envelope_storage_bytes(invocation_id)
  end

  @doc "Reports whether one worst-case provider envelope still fits in the configured ledger cap."
  @spec provider_response_storage_available?(
          Invocation.t() | pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: boolean()
  def provider_response_storage_available?(invocation, required_bytes, storage_limit)
      when is_integer(required_bytes) and required_bytes >= 0 and is_integer(storage_limit) and
             storage_limit > 0 do
    provider_response_storage_bytes(invocation) <= storage_limit - required_bytes
  end

  @spec pending_capacity_available?(pos_integer()) :: boolean()
  def pending_capacity_available?(maximum) when is_integer(maximum) and maximum > 0 do
    pending_count =
      Invocation
      |> where([invocation], invocation.status not in @terminal_statuses)
      |> Repo.aggregate(:count)

    pending_count < maximum
  end

  @spec received?(String.t(), String.t()) :: boolean()
  def received?(uri, cid) when is_binary(uri) and is_binary(cid) do
    Invocation
    |> where(
      [invocation],
      invocation.invocation_uri == ^uri and invocation.notification_cid == ^cid
    )
    |> Repo.exists?()
  end

  @spec fail(Invocation.t(), atom(), map()) :: {:ok, Invocation.t()}
  def fail(%Invocation{id: id}, category, detail) when is_map(detail) do
    {:ok, failed} =
      Repo.transaction(
        fn ->
          id
          |> then(&Repo.get!(Invocation, &1))
          |> Invocation.transition_changeset(%{
            status: :failed,
            stage: :failed,
            failure_category: Failure.category(category),
            failure_detail: detail,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update!()
        end,
        mode: :immediate
      )

    {:ok, failed}
  end

  defp receive_once(repo, attrs) do
    identity = [
      invocation_uri: attrs.invocation_uri,
      notification_cid: attrs.notification_cid
    ]

    case repo.get_by(Invocation, identity) do
      nil ->
        case repo.insert(Invocation.changeset(%Invocation{}, attrs)) do
          {:ok, invocation} -> {:ok, {invocation, :inserted}}
          {:error, changeset} -> {:error, changeset}
        end

      invocation ->
        {:ok, {invocation, :duplicate}}
    end
  end

  defp valid_dry_run_input?(target_uri, question) do
    target_uri != "" and is_binary(question) and String.valid?(question) and
      byte_size(question) <= @maximum_dry_run_question_bytes and String.trim(question) != ""
  end

  defp valid_live_run_receipt?(receipt) do
    valid_nonempty_string?(Map.get(receipt, :uri)) and
      valid_nonempty_string?(Map.get(receipt, :cid)) and
      valid_nonempty_string?(Map.get(receipt, :actor_did)) and
      valid_question?(Map.get(receipt, :invocation_text)) and is_map(Map.get(receipt, :raw)) and
      valid_optional_string?(Map.get(receipt, :actor_handle))
  end

  defp valid_question?(question) do
    is_binary(question) and String.valid?(question) and
      byte_size(question) <= @maximum_dry_run_question_bytes and String.trim(question) != ""
  end

  defp valid_question_canonical?(canonical) do
    canonical[:version] == 2 and is_binary(canonical[:text]) and canonical[:text] != "" and
      String.valid?(canonical[:text]) and is_list(canonical[:media]) and
      is_boolean(canonical[:contains_video])
  end

  defp valid_nonempty_string?(value),
    do: is_binary(value) and value != "" and String.valid?(value)

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: valid_nonempty_string?(value)

  defp create_or_attach_valid_live_run(receipt, received_at, job_builder) do
    result =
      Repo.transaction(
        fn -> live_run_decision(receipt, received_at, job_builder) end,
        mode: :immediate
      )

    case result do
      {:ok, {invocation, disposition}} ->
        {:ok, invocation, disposition}

      {:error, {:active_invocation, active}} ->
        {:error, :active_invocation, %{id: active.id, uri: active.invocation_uri}}

      {:error, {:contradictory_invocations, ids}} ->
        {:error, :contradictory_invocations, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp live_run_decision(receipt, received_at, job_builder) do
    matches = live_run_matches(receipt.uri)

    case matches do
      [existing] ->
        case different_active_invocation(existing.id) do
          nil -> {existing, live_run_disposition(existing)}
          active -> Repo.rollback({:active_invocation, active})
        end

      [] ->
        case different_active_invocation(nil) do
          nil -> insert_live_run!(receipt, received_at, job_builder)
          active -> Repo.rollback({:active_invocation, active})
        end

      contradictory ->
        Repo.rollback({:contradictory_invocations, Enum.map(contradictory, & &1.id)})
    end
  end

  defp live_run_matches(uri) do
    Invocation
    |> where([invocation], invocation.dry_run == false and invocation.invocation_uri == ^uri)
    |> order_by([invocation], asc: invocation.id)
    |> Repo.all()
  end

  defp different_active_invocation(excluded_id) do
    Invocation
    |> where([invocation], invocation.stage not in ^@terminal_statuses)
    |> exclude_invocation(excluded_id)
    |> order_by([invocation], asc: invocation.received_at, asc: invocation.id)
    |> limit(1)
    |> Repo.one()
  end

  defp exclude_invocation(query, nil), do: query
  defp exclude_invocation(query, id), do: where(query, [invocation], invocation.id != ^id)

  defp live_run_disposition(%Invocation{stage: :complete}), do: :complete

  defp live_run_disposition(%Invocation{stage: stage}) when stage in [:failed, :ineligible],
    do: :terminal

  defp live_run_disposition(%Invocation{}), do: :attached

  defp due_live_budget?(
         %Invocation{
           dry_run: false,
           stage: :deferred_budget,
           eligibility_method: "operator_live_demo",
           defer_until: %DateTime{} = defer_until
         },
         now
       ),
       do: DateTime.compare(defer_until, now) in [:lt, :eq]

  defp due_live_budget?(_invocation, _now), do: false

  defp resume_live_budget!(invocation, job_builder) do
    attrs = %{
      status: :thread_ready,
      stage: :thread_ready,
      defer_until: nil,
      research_claim_token: nil,
      research_claimed_at: nil,
      failure_category: nil,
      failure_detail: nil,
      completed_at: nil
    }

    case Repo.update(Invocation.transition_changeset(invocation, attrs)) do
      {:ok, resumed} ->
        case Repo.insert(job_builder.(resumed.invocation_uri, resumed.notification_cid)) do
          {:ok, _job} -> {resumed, :resumed}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_live_run!(receipt, received_at, job_builder) do
    attrs = %{
      dry_run: false,
      invocation_text: receipt.invocation_text,
      invocation_uri: receipt.uri,
      notification_cid: receipt.cid,
      current_cid: receipt.cid,
      actor_did: receipt.actor_did,
      actor_handle: receipt.actor_handle,
      raw_notification: receipt.raw,
      received_at: received_at,
      status: :capturing_thread,
      stage: :capturing_thread,
      eligibility_method: "operator_live_demo",
      eligibility_evidence: %{"source" => "explicit_local_command"},
      admitted_at: received_at
    }

    case Repo.insert(Invocation.changeset(%Invocation{}, attrs)) do
      {:ok, invocation} ->
        case Repo.insert(job_builder.(receipt.uri, receipt.cid)) do
          {:ok, _job} -> {invocation, :created}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp attachable_dry_run(target_uri, question) do
    Invocation
    |> where(
      [invocation],
      invocation.dry_run == true and invocation.target_uri == ^target_uri and
        invocation.invocation_text == ^question and
        invocation.stage not in ^@terminal_dry_run_stages
    )
    |> order_by([invocation], desc: invocation.received_at, desc: invocation.id)
    |> limit(1)
    |> Repo.one()
  end

  defp create_or_attach_valid_dry_run(target_uri, question, received_at, job_builder) do
    Repo.transaction(
      fn ->
        case attachable_dry_run(target_uri, question) do
          %Invocation{} = invocation -> {invocation, :attached}
          nil -> insert_dry_run!(target_uri, question, received_at, job_builder)
        end
      end,
      mode: :immediate
    )
    |> normalize_dry_run_transaction()
  end

  defp create_or_attach_valid_question_dry_run(question, canonical, received_at, job_builder) do
    Repo.transaction(
      fn ->
        case attachable_dry_run(@question_target_uri, question) do
          %Invocation{} = invocation -> {invocation, :attached}
          nil -> insert_question_dry_run!(question, canonical, received_at, job_builder)
        end
      end,
      mode: :immediate
    )
    |> normalize_dry_run_transaction()
  end

  defp insert_dry_run!(target_uri, question, received_at, job_builder) do
    run_id = Ecto.UUID.generate()
    invocation_uri = "local://context-bot/dry-runs/#{run_id}"
    notification_cid = "local:#{run_id}"

    attrs = %{
      dry_run: true,
      target_uri: target_uri,
      invocation_text: question,
      invocation_uri: invocation_uri,
      notification_cid: notification_cid,
      current_cid: notification_cid,
      actor_did: "local:operator",
      raw_notification: %{
        "source" => "local_dry_run",
        "target_uri" => target_uri,
        "text" => question
      },
      received_at: received_at,
      status: :capturing_thread,
      stage: :capturing_thread
    }

    case Repo.insert(Invocation.changeset(%Invocation{}, attrs)) do
      {:ok, invocation} ->
        case Repo.insert(job_builder.(invocation_uri, notification_cid)) do
          {:ok, _job} -> {invocation, :created}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_question_dry_run!(question, canonical, received_at, job_builder) do
    run_id = Ecto.UUID.generate()
    invocation_uri = "local://context-bot/dry-runs/#{run_id}"
    notification_cid = "local:#{run_id}"

    attrs = %{
      dry_run: true,
      target_uri: @question_target_uri,
      invocation_text: question,
      invocation_uri: invocation_uri,
      notification_cid: notification_cid,
      current_cid: notification_cid,
      actor_did: "local:operator",
      raw_notification: %{
        "source" => "local_question_dry_run",
        "text" => question
      },
      raw_thread: %{"source" => "local_question_dry_run"},
      canonical_thread: canonical.text,
      canonical_thread_version: Integer.to_string(canonical.version),
      canonical_media: canonical.media,
      contains_video: canonical.contains_video,
      received_at: received_at,
      status: :thread_ready,
      stage: :thread_ready
    }

    case Repo.insert(Invocation.changeset(%Invocation{}, attrs)) do
      {:ok, invocation} ->
        case Repo.insert(job_builder.(invocation_uri, notification_cid)) do
          {:ok, _job} -> {invocation, :created}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp normalize_dry_run_transaction({:ok, {invocation, disposition}}),
    do: {:ok, invocation, disposition}

  defp normalize_dry_run_transaction({:error, reason}), do: raise_transaction_error(reason)

  defp compare_and_update(repo, id, from_stage, attrs) do
    case repo.get(Invocation, id) do
      %Invocation{stage: ^from_stage} = invocation ->
        case repo.update(Invocation.transition_changeset(invocation, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end

      %Invocation{} ->
        {:error, :stale_stage}

      nil ->
        {:error, :stale_stage}
    end
  end

  defp compare_and_update_research(repo, id, token, attrs) do
    case repo.get(Invocation, id) do
      %Invocation{stage: :researching, research_claim_token: ^token} = invocation ->
        case repo.update(Invocation.transition_changeset(invocation, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end

      %Invocation{} ->
        {:error, :stale_claim}

      nil ->
        {:error, :stale_claim}
    end
  end

  defp compare_and_update_publication(repo, id, token, attrs) do
    case repo.get(Invocation, id) do
      %Invocation{stage: :publishing, publication_claim_token: ^token} = invocation ->
        case repo.update(Invocation.transition_changeset(invocation, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end

      %Invocation{} ->
        {:error, :stale_claim}

      nil ->
        {:error, :stale_claim}
    end
  end

  defp research_transition_attrs(attrs, token, :researching, now) do
    attrs
    |> Map.drop([:status, "status", :stage, "stage", :research_claim_token])
    |> Map.merge(%{
      status: :researching,
      stage: :researching,
      research_claim_token: token,
      research_claimed_at: now
    })
  end

  defp research_transition_attrs(attrs, _token, to_stage, _now) do
    attrs
    |> Map.drop([:status, "status", :stage, "stage", :research_claim_token])
    |> Map.merge(%{
      status: to_stage,
      stage: to_stage,
      research_claim_token: nil,
      research_claimed_at: nil
    })
  end

  defp research_claimable?(%Invocation{stage: :thread_ready}, _token, _now, _stale_before),
    do: true

  defp research_claimable?(
         %Invocation{stage: :deferred_budget, defer_until: defer_until},
         _token,
         now,
         _stale_before
       ),
       do: is_nil(defer_until) or DateTime.compare(defer_until, now) in [:lt, :eq]

  defp research_claimable?(
         %Invocation{
           stage: :researching,
           research_claim_token: existing_token,
           research_claimed_at: claimed_at
         },
         token,
         _now,
         stale_before
       ) do
    is_nil(existing_token) or existing_token == token or is_nil(claimed_at) or
      DateTime.compare(claimed_at, stale_before) in [:lt, :eq]
  end

  defp research_claimable?(_invocation, _token, _now, _stale_before), do: false

  defp publication_claimable?(%Invocation{dry_run: true}, _token, _stale_before), do: false

  defp publication_claimable?(%Invocation{stage: :reply_ready}, _token, _stale_before), do: true

  defp publication_claimable?(
         %Invocation{
           stage: :publishing,
           publication_claim_token: existing_token,
           publication_claimed_at: claimed_at
         },
         token,
         stale_before
       ) do
    is_nil(existing_token) or existing_token == token or is_nil(claimed_at) or
      DateTime.compare(claimed_at, stale_before) in [:lt, :eq]
  end

  defp publication_claimable?(_invocation, _token, _stale_before), do: false

  defp persist_research_claim(invocation, token, now) do
    result =
      invocation
      |> Invocation.transition_changeset(%{
        status: :researching,
        stage: :researching,
        defer_until: nil,
        research_claim_token: token,
        research_claimed_at: now,
        failure_category: nil,
        failure_detail: nil,
        completed_at: nil
      })
      |> Repo.update()

    case result do
      {:ok, claimed} -> claimed
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp persist_publication_claim(invocation, token, now) do
    result =
      invocation
      |> Invocation.transition_changeset(%{
        status: :publishing,
        stage: :publishing,
        publication_claim_token: token,
        publication_claimed_at: latest_timestamp(invocation.publication_claimed_at, now),
        failure_category: nil,
        failure_detail: nil,
        completed_at: nil
      })
      |> Repo.update()

    case result do
      {:ok, claimed} -> claimed
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp research_claim_error(%Invocation{stage: :researching}, _now), do: :busy

  defp research_claim_error(
         %Invocation{stage: :deferred_budget, defer_until: %DateTime{} = defer_until},
         now
       ) do
    if DateTime.compare(defer_until, now) == :gt, do: :busy, else: :stale_stage
  end

  defp research_claim_error(_invocation, _now), do: :stale_stage

  defp publication_claim_error(%Invocation{stage: :publishing}), do: :busy
  defp publication_claim_error(_invocation), do: :stale_stage

  defp maybe_insert_job(_repo, false, _next_job), do: {:ok, nil}
  defp maybe_insert_job(_repo, true, nil), do: {:ok, nil}
  defp maybe_insert_job(repo, true, %Changeset{} = next_job), do: repo.insert(next_job)

  defp research_claim_context(invocation_id) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> select([invocation], %{
      stage: invocation.stage,
      token: invocation.research_claim_token,
      claimed_at: invocation.research_claimed_at
    })
    |> Repo.one!()
  end

  defp publication_claim_context(invocation_id) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> select([invocation], %{
      stage: invocation.stage,
      token: invocation.publication_claim_token,
      claimed_at: invocation.publication_claimed_at
    })
    |> Repo.one!()
  end

  defp authorize_research_claim!(invocation_id, token) do
    case research_claim_context(invocation_id) do
      %{stage: :researching, token: ^token} -> :ok
      _stale -> Repo.rollback(:stale_claim)
    end
  end

  defp renew_research_claim_at(invocation_id, token, now) do
    %{claimed_at: claimed_at} = research_claim_context(invocation_id)

    Invocation
    |> where(
      [invocation],
      invocation.id == ^invocation_id and invocation.stage == :researching and
        invocation.research_claim_token == ^token
    )
    |> Repo.update_all(set: [research_claimed_at: latest_timestamp(claimed_at, now)])

    :ok
  end

  defp enforce_response_storage_limit!(invocation_id, new_size, storage_limit) do
    if provider_response_storage_bytes(invocation_id) > storage_limit - new_size do
      Repo.rollback(:provider_storage_limit)
    end
  end

  defp response_envelope_storage_bytes(invocation_id) do
    ResponseEnvelope
    |> where([response], response.invocation_id == ^invocation_id)
    |> select([response], coalesce(sum(response.storage_bytes), 0))
    |> Repo.one()
  end

  defp legacy_storage_bytes(invocation_id) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> select([invocation], fragment("COALESCE(length(?), 0)", invocation.anthropic_responses))
    |> Repo.one()
  end

  defp legacy_responses(invocation_id) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> select([invocation], invocation.anthropic_responses)
    |> Repo.one()
  end

  defp latest_timestamp(nil, now), do: now

  defp latest_timestamp(claimed_at, now) do
    if DateTime.compare(claimed_at, now) == :gt, do: claimed_at, else: now
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp fetch!(map, key) do
    case fetch(map, key) do
      nil -> raise KeyError, key: key, term: map
      value -> value
    end
  end

  defp raise_transaction_error(%Changeset{} = changeset) do
    raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
  end

  defp raise_transaction_error(reason),
    do: raise("invocation receipt transaction failed: #{inspect(reason)}")

  defp follower_published?(%Invocation{follower_post_uri: uri, follower_post_cid: cid})
       when is_binary(uri) and uri != "" and is_binary(cid) and cid != "",
       do: true

  defp follower_published?(_invocation), do: false

  defp persist_follower_post!(current, attrs) do
    allowed = %{
      follower_post_rkey: Map.get(attrs, :follower_post_rkey),
      follower_post_record: Map.get(attrs, :follower_post_record),
      follower_post_uri: Map.get(attrs, :follower_post_uri),
      follower_post_cid: Map.get(attrs, :follower_post_cid)
    }

    updates =
      allowed
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Repo.update(Invocation.transition_changeset(current, updates)) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp transact_limit_notice(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_limit_notice!(id, stage, kind) do
    claim_limit_notice_from!(Repo.get!(Invocation, id), stage, kind)
  end

  defp claim_limit_notice_from!(current, stage, kind) do
    cond do
      current.stage != stage -> Repo.rollback(:stale_stage)
      current.dry_run -> Repo.rollback(:dry_run)
      not is_nil(current.limit_notice_kind) -> Repo.rollback(:already_claimed)
      true -> update_limit_notice!(current, %{limit_notice_kind: kind})
    end
  end

  defp record_limit_notice!(id, stage, uri, cid, posted_at) do
    record_limit_notice_from!(Repo.get!(Invocation, id), stage, uri, cid, posted_at)
  end

  defp record_limit_notice_from!(current, stage, uri, cid, posted_at) do
    if current.stage != stage or is_nil(current.limit_notice_kind) do
      Repo.rollback(:stale_stage)
    else
      update_limit_notice!(current, %{
        limit_notice_uri: uri,
        limit_notice_cid: cid,
        limit_notice_posted_at: posted_at
      })
    end
  end

  defp update_limit_notice!(invocation, attrs) do
    case Repo.update(Invocation.transition_changeset(invocation, attrs)) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
