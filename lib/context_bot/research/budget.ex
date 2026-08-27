defmodule ContextBot.Research.Budget do
  @moduledoc """
  Atomic UTC-day Anthropic budget reservations and exposure settlement.

  Claimed research uses token-aware operations so a worker that lost its lease cannot reserve,
  expose, reconcile, or settle an attempt. Network I/O never belongs inside these short immediate
  SQLite transactions.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{BudgetEntry, Pricing, ResponseEnvelope}
  alias ContextBot.Workflow.Invocation

  @type mutation_error :: :daily_budget_exhausted | :stale_claim
  @type claim_token :: String.t() | nil

  @spec unrecorded_exposed_attempt(Invocation.t()) :: BudgetEntry.t() | nil
  def unrecorded_exposed_attempt(%Invocation{} = invocation) do
    invocation
    |> unrecorded_exposed_attempts()
    |> List.first()
  end

  @spec unrecorded_exposed_attempts(Invocation.t()) :: [BudgetEntry.t()]
  def unrecorded_exposed_attempts(%Invocation{id: invocation_id}) do
    BudgetEntry
    |> join(:left, [entry], envelope in ResponseEnvelope,
      on: envelope.budget_entry_id == entry.id
    )
    |> where(
      [entry, envelope],
      entry.invocation_id == ^invocation_id and
        entry.state in [:sent, :indeterminate] and is_nil(envelope.id)
    )
    |> order_by([entry], asc: entry.id)
    |> Repo.all()
  end

  @spec mark_unrecorded_exposed_indeterminate(Invocation.t()) :: :ok
  def mark_unrecorded_exposed_indeterminate(%Invocation{} = invocation) do
    invocation
    |> unrecorded_exposed_attempts()
    |> Enum.each(&mark_entry_indeterminate/1)

    :ok
  end

  @spec reserve_next(
          Invocation.t(),
          BudgetEntry.kind(),
          DateTime.t(),
          pos_integer(),
          pos_integer()
        ) ::
          {:ok, BudgetEntry.t()} | {:error, mutation_error()}
  def reserve_next(invocation, kind, now, amount, daily_limit),
    do: reserve_next(invocation, kind, now, amount, daily_limit, nil)

  @spec reserve_next(
          Invocation.t(),
          BudgetEntry.kind(),
          DateTime.t(),
          pos_integer(),
          pos_integer(),
          claim_token()
        ) :: {:ok, BudgetEntry.t()} | {:error, mutation_error()}
  def reserve_next(
        %Invocation{id: invocation_id},
        kind,
        %DateTime{} = now,
        amount,
        daily_limit,
        claim_token
      )
      when is_integer(amount) and amount > 0 and is_integer(daily_limit) and daily_limit > 0 and
             (is_nil(claim_token) or (is_binary(claim_token) and claim_token != "")) do
    budget_date = utc_date(now)

    result =
      Repo.transaction(
        fn ->
          context = claim_context(invocation_id)
          authorize_claim!(context, claim_token)

          if charged_on(budget_date) > daily_limit - amount do
            Repo.rollback(:daily_budget_exhausted)
          end

          sequence = context.sequence + 1

          persist_sequence_and_renew(
            invocation_id,
            sequence,
            context.claimed_at,
            claim_token,
            now
          )

          attempt_key = "invocation-#{invocation_id}-attempt-#{sequence}-#{kind}"

          %BudgetEntry{}
          |> BudgetEntry.changeset(%{
            attempt_key: attempt_key,
            invocation_id: invocation_id,
            budget_date: budget_date,
            kind: kind,
            reserved_microdollars: amount,
            research_claim_token: claim_token,
            state: :reserved
          })
          |> Repo.insert!()
        end,
        mode: :immediate
      )

    normalize_mutation_result(result)
  end

  @spec remaining(DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def remaining(%DateTime{} = now, daily_limit)
      when is_integer(daily_limit) and daily_limit >= 0 do
    max(daily_limit - charged_on(utc_date(now)), 0)
  end

  @spec mark_sent(BudgetEntry.t(), DateTime.t()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_sent(entry, sent_at), do: mark_sent(entry, sent_at, nil)

  @spec mark_sent(BudgetEntry.t(), DateTime.t(), claim_token()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_sent(%BudgetEntry{id: id}, %DateTime{} = sent_at, claim_token) do
    update_immediately(id, claim_token, sent_at, fn entry ->
      authorize_attempt_owner!(entry, claim_token)

      case entry do
        %BudgetEntry{state: :reserved} ->
          entry
          |> BudgetEntry.changeset(%{state: :sent, sent_at: sent_at})
          |> Repo.update!()

        entry ->
          entry
      end
    end)
  end

  @spec mark_response_recorded(BudgetEntry.t(), DateTime.t()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_response_recorded(%BudgetEntry{id: id}, %DateTime{} = recorded_at) do
    update_immediately(id, nil, recorded_at, fn
      %BudgetEntry{state: :sent, response_recorded_at: nil} = entry ->
        entry
        |> BudgetEntry.changeset(%{response_recorded_at: recorded_at})
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec settle(BudgetEntry.t(), map(), Pricing.t()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def settle(entry, usage, pricing),
    do: settle(entry, usage, pricing, DateTime.utc_now(), nil)

  @spec settle(BudgetEntry.t(), map(), Pricing.t(), DateTime.t(), claim_token()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def settle(%BudgetEntry{id: id}, usage, %Pricing{} = pricing, %DateTime{} = now, claim_token)
      when is_map(usage) do
    calculated = Pricing.calculate(usage, pricing)

    update_immediately(id, claim_token, now, fn
      %BudgetEntry{state: state, response_recorded_at: %DateTime{}} = entry
      when state in [:sent, :indeterminate] ->
        settlement_attrs(entry, usage, pricing, calculated)
        |> then(&BudgetEntry.changeset(entry, &1))
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec mark_indeterminate(BudgetEntry.t()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_indeterminate(entry),
    do: mark_indeterminate(entry, DateTime.utc_now(), nil)

  @spec mark_indeterminate(BudgetEntry.t(), DateTime.t(), claim_token()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_indeterminate(%BudgetEntry{id: id}, %DateTime{} = now, claim_token) do
    update_immediately(id, claim_token, now, fn entry ->
      authorize_attempt_owner!(entry, claim_token)

      case entry do
        %BudgetEntry{state: :sent, response_recorded_at: nil} ->
          entry
          |> BudgetEntry.changeset(%{state: :indeterminate, settled_microdollars: nil})
          |> Repo.update!()

        entry ->
          entry
      end
    end)
  end

  @spec mark_unrecorded_indeterminate(BudgetEntry.t(), DateTime.t(), claim_token()) ::
          {:ok, BudgetEntry.t()} | {:error, :stale_claim}
  def mark_unrecorded_indeterminate(%BudgetEntry{id: id}, %DateTime{} = now, claim_token) do
    update_immediately(id, claim_token, now, fn entry ->
      if response_envelope_exists?(entry) do
        entry
      else
        mark_entry_indeterminate(entry)
      end
    end)
  end

  defp response_envelope_exists?(entry) do
    Repo.exists?(from envelope in ResponseEnvelope, where: envelope.budget_entry_id == ^entry.id)
  end

  defp mark_entry_indeterminate(%BudgetEntry{state: :sent} = entry) do
    entry
    |> BudgetEntry.changeset(%{state: :indeterminate, settled_microdollars: nil})
    |> Repo.update!()
  end

  defp mark_entry_indeterminate(entry), do: entry

  @spec reconcile_attempt(BudgetEntry.t()) ::
          {:reuse, BudgetEntry.t()}
          | {:resume, BudgetEntry.t()}
          | {:indeterminate, BudgetEntry.t()}
          | {:complete, BudgetEntry.t()}
          | {:error, :stale_claim}
  def reconcile_attempt(entry),
    do: reconcile_attempt(entry, DateTime.utc_now(), nil)

  @spec reconcile_attempt(BudgetEntry.t(), DateTime.t(), claim_token()) ::
          {:reuse, BudgetEntry.t()}
          | {:resume, BudgetEntry.t()}
          | {:indeterminate, BudgetEntry.t()}
          | {:complete, BudgetEntry.t()}
          | {:error, :stale_claim}
  def reconcile_attempt(%BudgetEntry{id: id}, %DateTime{} = now, claim_token) do
    result =
      Repo.transaction(
        fn ->
          entry = Repo.get!(BudgetEntry, id)
          context = claim_context(entry.invocation_id)
          authorize_claim!(context, claim_token)
          renew_claim(entry.invocation_id, context.claimed_at, claim_token, now)
          reconcile_entry(entry, claim_token)
        end,
        mode: :immediate
      )

    case result do
      {:ok, reconciliation} -> reconciliation
      {:error, :stale_claim} -> {:error, :stale_claim}
    end
  end

  defp reconcile_entry(%BudgetEntry{state: :reserved} = entry, claim_token) do
    entry =
      if entry.research_claim_token == claim_token do
        entry
      else
        entry
        |> BudgetEntry.changeset(%{research_claim_token: claim_token})
        |> Repo.update!()
      end

    {:reuse, entry}
  end

  defp reconcile_entry(
         %BudgetEntry{state: :sent, response_recorded_at: nil} = entry,
         _claim_token
       ) do
    entry =
      entry
      |> BudgetEntry.changeset(%{state: :indeterminate, settled_microdollars: nil})
      |> Repo.update!()

    {:indeterminate, entry}
  end

  defp reconcile_entry(%BudgetEntry{state: :sent} = entry, _claim_token),
    do: {:resume, entry}

  defp reconcile_entry(entry, _claim_token), do: {:complete, entry}

  defp settlement_attrs(entry, usage, pricing, {:ok, settled})
       when settled <= entry.reserved_microdollars do
    %{
      state: :settled,
      settled_microdollars: settled,
      usage: usage,
      pricing_version: pricing.version
    }
  end

  defp settlement_attrs(_entry, usage, pricing, _unsafe_or_over_reservation) do
    %{
      state: :indeterminate,
      settled_microdollars: nil,
      usage: usage,
      pricing_version: pricing.version
    }
  end

  defp charged_on(budget_date) do
    BudgetEntry
    |> where([entry], entry.budget_date == ^budget_date)
    |> select(
      [entry],
      fragment(
        "COALESCE(SUM(CASE WHEN ? = 'settled' THEN COALESCE(?, ?) ELSE ? END), 0)",
        entry.state,
        entry.settled_microdollars,
        entry.reserved_microdollars,
        entry.reserved_microdollars
      )
    )
    |> Repo.one()
  end

  defp update_immediately(id, claim_token, now, update) do
    result =
      Repo.transaction(
        fn ->
          entry = Repo.get!(BudgetEntry, id)
          context = claim_context(entry.invocation_id)
          authorize_claim!(context, claim_token)
          renew_claim(entry.invocation_id, context.claimed_at, claim_token, now)
          update.(entry)
        end,
        mode: :immediate
      )

    normalize_mutation_result(result)
  end

  defp claim_context(invocation_id) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> select([invocation], %{
      stage: invocation.stage,
      token: invocation.research_claim_token,
      claimed_at: invocation.research_claimed_at,
      sequence: invocation.anthropic_attempt_sequence
    })
    |> Repo.one!()
  end

  defp authorize_claim!(%{token: nil}, nil), do: :ok

  defp authorize_claim!(%{stage: :researching, token: token}, token)
       when is_binary(token) and token != "",
       do: :ok

  defp authorize_claim!(_context, _claim_token), do: Repo.rollback(:stale_claim)

  defp authorize_attempt_owner!(%BudgetEntry{research_claim_token: token}, token), do: :ok
  defp authorize_attempt_owner!(_entry, _claim_token), do: Repo.rollback(:stale_claim)

  defp persist_sequence_and_renew(
         invocation_id,
         sequence,
         claimed_at,
         claim_token,
         now
       ) do
    updates =
      if is_nil(claim_token) do
        [set: [anthropic_attempt_sequence: sequence]]
      else
        [
          set: [
            anthropic_attempt_sequence: sequence,
            research_claimed_at: latest_timestamp(claimed_at, now)
          ]
        ]
      end

    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> Repo.update_all(updates)
  end

  defp renew_claim(_invocation_id, _claimed_at, nil, _now), do: :ok

  defp renew_claim(invocation_id, claimed_at, _claim_token, now) do
    Invocation
    |> where([invocation], invocation.id == ^invocation_id)
    |> Repo.update_all(set: [research_claimed_at: latest_timestamp(claimed_at, now)])

    :ok
  end

  defp latest_timestamp(nil, now), do: now

  defp latest_timestamp(claimed_at, now) do
    if DateTime.compare(claimed_at, now) == :gt, do: claimed_at, else: now
  end

  defp normalize_mutation_result({:ok, value}), do: {:ok, value}
  defp normalize_mutation_result({:error, :stale_claim}), do: {:error, :stale_claim}

  defp normalize_mutation_result({:error, :daily_budget_exhausted}),
    do: {:error, :daily_budget_exhausted}

  defp utc_date(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
  end
end
