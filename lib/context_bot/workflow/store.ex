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
  alias ContextBot.Research.BudgetEntry
  alias ContextBot.Workflow.{Failure, Invocation}
  alias Ecto.{Changeset, Multi}

  @terminal_statuses [:ineligible, :complete, :failed]

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

  @spec append_anthropic_response(Invocation.t(), map(), pos_integer()) ::
          {:ok, Invocation.t()} | {:error, :provider_storage_limit}
  def append_anthropic_response(%Invocation{id: id}, response, storage_limit)
      when is_map(response) and is_integer(storage_limit) and storage_limit > 0 do
    result =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, id)
          persisted_response = json_round_trip(response)
          responses = invocation.anthropic_responses ++ [persisted_response]

          if encoded_size(responses) > storage_limit do
            Repo.rollback(:provider_storage_limit)
          end

          invocation
          |> Invocation.anthropic_responses_changeset(responses)
          |> Repo.update!()
        end,
        mode: :immediate
      )

    case result do
      {:ok, invocation} -> {:ok, invocation}
      {:error, :provider_storage_limit} -> {:error, :provider_storage_limit}
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
          DateTime.t()
        ) ::
          {:ok, Invocation.t(), BudgetEntry.t()}
          | {:error, :provider_storage_limit | :invalid_attempt_state}
  def record_anthropic_response(
        %Invocation{id: invocation_id},
        %BudgetEntry{id: entry_id},
        response,
        storage_limit,
        %DateTime{} = recorded_at
      )
      when is_map(response) and is_integer(storage_limit) and storage_limit > 0 do
    result =
      Repo.transaction(
        fn ->
          invocation = Repo.get!(Invocation, invocation_id)
          entry = Repo.get!(BudgetEntry, entry_id)

          if entry.invocation_id != invocation.id or entry.state != :sent or
               entry.response_recorded_at != nil do
            Repo.rollback(:invalid_attempt_state)
          end

          persisted_response = json_round_trip(response)
          responses = invocation.anthropic_responses ++ [persisted_response]

          if encoded_size(responses) > storage_limit do
            Repo.rollback(:provider_storage_limit)
          end

          invocation =
            invocation
            |> Invocation.anthropic_responses_changeset(responses)
            |> Repo.update!()

          entry =
            entry
            |> BudgetEntry.changeset(%{response_recorded_at: recorded_at})
            |> Repo.update!()

          {invocation, entry}
        end,
        mode: :immediate
      )

    case result do
      {:ok, {invocation, entry}} ->
        {:ok, invocation, entry}

      {:error, reason} when reason in [:provider_storage_limit, :invalid_attempt_state] ->
        {:error, reason}
    end
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

  defp research_claim_error(%Invocation{stage: :researching}, _now), do: :busy

  defp research_claim_error(
         %Invocation{stage: :deferred_budget, defer_until: %DateTime{} = defer_until},
         now
       ) do
    if DateTime.compare(defer_until, now) == :gt, do: :busy, else: :stale_stage
  end

  defp research_claim_error(_invocation, _now), do: :stale_stage

  defp maybe_insert_job(_repo, false, _next_job), do: {:ok, nil}
  defp maybe_insert_job(_repo, true, nil), do: {:ok, nil}
  defp maybe_insert_job(repo, true, %Changeset{} = next_job), do: repo.insert(next_job)

  defp encoded_size(value) do
    value
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
  end

  defp json_round_trip(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
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
end
