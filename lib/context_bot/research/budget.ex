defmodule ContextBot.Research.Budget do
  @moduledoc """
  Atomic UTC-day Anthropic budget reservations and exposure settlement.

  Network I/O never belongs inside these short immediate SQLite transactions.
  """

  import Ecto.Query

  alias ContextBot.Repo
  alias ContextBot.Research.{BudgetEntry, Pricing}
  alias ContextBot.Workflow.Invocation

  @spec reserve_next(
          Invocation.t(),
          BudgetEntry.kind(),
          DateTime.t(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, BudgetEntry.t()} | {:error, :daily_budget_exhausted}
  def reserve_next(
        %Invocation{id: invocation_id},
        kind,
        %DateTime{} = now,
        amount,
        daily_limit
      )
      when is_integer(amount) and amount > 0 and is_integer(daily_limit) and daily_limit > 0 do
    budget_date = utc_date(now)

    result =
      Repo.transaction(
        fn ->
          if charged_on(budget_date) > daily_limit - amount do
            Repo.rollback(:daily_budget_exhausted)
          end

          invocation = Repo.get!(Invocation, invocation_id)
          sequence = invocation.anthropic_attempt_sequence + 1

          invocation
          |> Ecto.Changeset.change(anthropic_attempt_sequence: sequence)
          |> Repo.update!()

          attempt_key = "invocation-#{invocation_id}-attempt-#{sequence}-#{kind}"

          %BudgetEntry{}
          |> BudgetEntry.changeset(%{
            attempt_key: attempt_key,
            invocation_id: invocation_id,
            budget_date: budget_date,
            kind: kind,
            reserved_microdollars: amount,
            state: :reserved
          })
          |> Repo.insert!()
        end,
        mode: :immediate
      )

    case result do
      {:ok, entry} -> {:ok, entry}
      {:error, :daily_budget_exhausted} -> {:error, :daily_budget_exhausted}
    end
  end

  @spec remaining(DateTime.t(), non_neg_integer()) :: non_neg_integer()
  def remaining(%DateTime{} = now, daily_limit)
      when is_integer(daily_limit) and daily_limit >= 0 do
    max(daily_limit - charged_on(utc_date(now)), 0)
  end

  @spec mark_sent(BudgetEntry.t(), DateTime.t()) :: {:ok, BudgetEntry.t()}
  def mark_sent(%BudgetEntry{id: id}, %DateTime{} = sent_at) do
    update_immediately(id, fn
      %BudgetEntry{state: :reserved} = entry ->
        entry
        |> BudgetEntry.changeset(%{state: :sent, sent_at: sent_at})
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec mark_response_recorded(BudgetEntry.t(), DateTime.t()) :: {:ok, BudgetEntry.t()}
  def mark_response_recorded(%BudgetEntry{id: id}, %DateTime{} = recorded_at) do
    update_immediately(id, fn
      %BudgetEntry{state: :sent, response_recorded_at: nil} = entry ->
        entry
        |> BudgetEntry.changeset(%{response_recorded_at: recorded_at})
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec settle(BudgetEntry.t(), map(), Pricing.t()) :: {:ok, BudgetEntry.t()}
  def settle(%BudgetEntry{id: id}, usage, %Pricing{} = pricing) when is_map(usage) do
    calculated = Pricing.calculate(usage, pricing)

    update_immediately(id, fn
      %BudgetEntry{state: :sent, response_recorded_at: %DateTime{}} = entry ->
        settlement_attrs(entry, usage, pricing, calculated)
        |> then(&BudgetEntry.changeset(entry, &1))
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec mark_indeterminate(BudgetEntry.t()) :: {:ok, BudgetEntry.t()}
  def mark_indeterminate(%BudgetEntry{id: id}) do
    update_immediately(id, fn
      %BudgetEntry{state: :sent} = entry ->
        entry
        |> BudgetEntry.changeset(%{state: :indeterminate, settled_microdollars: nil})
        |> Repo.update!()

      entry ->
        entry
    end)
  end

  @spec reconcile_attempt(BudgetEntry.t()) ::
          {:reuse, BudgetEntry.t()}
          | {:resume, BudgetEntry.t()}
          | {:indeterminate, BudgetEntry.t()}
          | {:complete, BudgetEntry.t()}
  def reconcile_attempt(%BudgetEntry{id: id}) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          case Repo.get!(BudgetEntry, id) do
            %BudgetEntry{state: :reserved} = entry ->
              {:reuse, entry}

            %BudgetEntry{state: :sent, response_recorded_at: nil} = entry ->
              entry =
                entry
                |> BudgetEntry.changeset(%{
                  state: :indeterminate,
                  settled_microdollars: nil
                })
                |> Repo.update!()

              {:indeterminate, entry}

            %BudgetEntry{state: :sent} = entry ->
              {:resume, entry}

            entry ->
              {:complete, entry}
          end
        end,
        mode: :immediate
      )

    result
  end

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

  defp update_immediately(id, update) do
    {:ok, entry} =
      Repo.transaction(
        fn -> id |> then(&Repo.get!(BudgetEntry, &1)) |> update.() end,
        mode: :immediate
      )

    {:ok, entry}
  end

  defp utc_date(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_date()
  end
end
