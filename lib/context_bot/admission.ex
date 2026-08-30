defmodule ContextBot.Admission do
  @moduledoc """
  Atomically applies rolling admission limits and hands admitted work to thread capture.

  No external I/O occurs inside the immediate SQLite transaction.
  """

  import Ecto.Query

  alias ContextBot.{Repo, Settings}
  alias ContextBot.Workflow.Invocation
  alias Ecto.Changeset

  @terminal_statuses [:ineligible, :complete, :failed]
  @thread_worker "ContextBot.Workers.ThreadWorker"

  @spec capacity_available?(Settings.t()) :: boolean()
  def capacity_available?(%Settings{max_pending: maximum}) do
    pending_count() < maximum
  end

  @doc "Checks capacity while excluding the workflow that is being reconsidered."
  @spec capacity_available?(Settings.t(), pos_integer()) :: boolean()
  def capacity_available?(%Settings{max_pending: maximum}, excluded_invocation_id)
      when is_integer(excluded_invocation_id) and excluded_invocation_id > 0 do
    pending_count(excluded_invocation_id) < maximum
  end

  @doc "Read-only admission gate for an already accepted workflow resuming after deferral."
  @spec resume_available?(Invocation.t(), DateTime.t(), Settings.t()) :: boolean()
  def resume_available?(%Invocation{id: id} = invocation, %DateTime{} = now, settings) do
    capacity_available?(settings, id) and
      is_nil(rate_defer_until(invocation, now, settings, id))
  end

  @spec admit(Invocation.t(), DateTime.t(), Settings.t(), Changeset.t()) ::
          {:ok, Invocation.t()}
          | {:deferred, :actor_rate | :rate | :capacity, Invocation.t()}
  def admit(
        %Invocation{id: id} = invocation,
        %DateTime{} = now,
        %Settings{} = settings,
        %Changeset{} = thread_job
      ) do
    validate_thread_job!(thread_job, invocation)
    finalize_admission(run_admission(id, now, settings, thread_job))
  end

  defp run_admission(id, now, settings, thread_job) do
    Repo.transaction(
      fn ->
        invocation = Repo.get!(Invocation, id)
        apply_admission(invocation, now, settings, thread_job)
      end,
      mode: :immediate
    )
  end

  defp apply_admission(invocation, now, settings, thread_job) do
    if invocation.stage != :checking_eligibility do
      Repo.rollback(:stale_stage)
    end

    apply_admission_decision(
      admission_decision(invocation, now, settings),
      invocation,
      now,
      thread_job
    )
  end

  defp apply_admission_decision(:capacity, invocation, _now, _thread_job) do
    {:capacity, defer(invocation, :deferred_capacity, nil)}
  end

  defp apply_admission_decision({:actor_rate, actor_until}, invocation, _now, _thread_job) do
    {:actor_rate, defer(invocation, :deferred_rate, actor_until)}
  end

  defp apply_admission_decision({:rate, global_until}, invocation, _now, _thread_job) do
    {:rate, defer(invocation, :deferred_rate, global_until)}
  end

  defp apply_admission_decision(:admit, invocation, now, thread_job) do
    admitted =
      invocation
      |> Invocation.transition_changeset(%{
        status: :capturing_thread,
        stage: :capturing_thread,
        admitted_at: now,
        defer_until: nil
      })
      |> Repo.update!()

    Repo.insert!(thread_job)
    {:admitted, admitted}
  end

  defp finalize_admission({:ok, {:admitted, invocation}}), do: {:ok, invocation}

  defp finalize_admission({:ok, {:actor_rate, invocation}}),
    do: {:deferred, :actor_rate, invocation}

  defp finalize_admission({:ok, {:rate, invocation}}), do: {:deferred, :rate, invocation}
  defp finalize_admission({:ok, {:capacity, invocation}}), do: {:deferred, :capacity, invocation}

  defp finalize_admission({:error, :stale_stage}) do
    raise ArgumentError, "invocation is no longer checking eligibility"
  end

  defp admission_decision(invocation, now, settings) do
    cond do
      pending_count(invocation.id) >= settings.max_pending ->
        :capacity

      actor_until = actor_rate_defer_until(invocation, now, settings) ->
        {:actor_rate, actor_until}

      global_until = global_rate_defer_until(now, settings) ->
        {:rate, global_until}

      true ->
        :admit
    end
  end

  defp defer(invocation, status, defer_until) do
    invocation
    |> Invocation.transition_changeset(%{
      status: status,
      stage: status,
      admitted_at: nil,
      defer_until: defer_until
    })
    |> Repo.update!()
  end

  defp rate_defer_until(%Invocation{} = invocation, now, settings, excluded_invocation_id) do
    [
      actor_rate_defer_until(invocation, now, settings, excluded_invocation_id),
      global_rate_defer_until(now, settings, excluded_invocation_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp actor_rate_defer_until(
         %Invocation{} = invocation,
         now,
         settings,
         excluded_invocation_id \\ nil
       ) do
    if skip_actor_rate_windows?(invocation.actor_did, settings) do
      nil
    else
      [
        breached_window(
          invocation.actor_did,
          now,
          :hour,
          settings.actor_hourly_limit,
          excluded_invocation_id
        ),
        breached_window(
          invocation.actor_did,
          now,
          :day,
          actor_daily_limit(invocation, settings),
          excluded_invocation_id
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)
    end
  end

  defp global_rate_defer_until(now, settings, excluded_invocation_id \\ nil) do
    [
      breached_window(nil, now, :hour, settings.global_hourly_limit, excluded_invocation_id),
      breached_window(nil, now, :day, settings.global_daily_limit, excluded_invocation_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # Operator allowlisting skips only actor hourly/daily windows. Global and
  # max_pending capacity still apply, including for resume_available?/3.
  defp skip_actor_rate_windows?(actor_did, %Settings{operator_allowed_dids: allowed})
       when is_binary(actor_did),
       do: actor_did in allowed

  defp skip_actor_rate_windows?(_actor_did, _settings), do: false

  # Elders and verified bsky.team share ACTOR_DAILY_LIMIT. Everyone else,
  # including an unclassified or public mention, uses ACTOR_DAILY_LIMIT_PUBLIC.
  # Daily tiers are the actor cap; ACTOR_HOURLY_LIMIT remains a burst window.
  defp actor_daily_limit(%Invocation{eligibility_method: method}, settings)
       when method in ["bluesky_elder", "bsky_team"],
       do: settings.actor_daily_limit

  defp actor_daily_limit(_invocation, settings), do: settings.actor_daily_limit_public

  defp breached_window(actor_did, now, window, limit, excluded_invocation_id) do
    window_seconds = window_seconds(window)
    cutoff = DateTime.add(now, -window_seconds, :second)

    query =
      from invocation in Invocation,
        where:
          invocation.admitted_at > ^cutoff and
            invocation.admitted_at <= ^now,
        select: {count(invocation.id), min(invocation.admitted_at)}

    query =
      if actor_did do
        where(query, [invocation], invocation.actor_did == ^actor_did)
      else
        query
      end

    query =
      if excluded_invocation_id do
        where(query, [invocation], invocation.id != ^excluded_invocation_id)
      else
        query
      end

    case Repo.one(query) do
      {count, earliest_admission} when count >= limit ->
        DateTime.add(earliest_admission, window_seconds, :second)

      _below_limit ->
        nil
    end
  end

  defp window_seconds(:hour), do: 60 * 60
  defp window_seconds(:day), do: 24 * 60 * 60

  defp pending_count(excluded_invocation_id \\ nil) do
    query =
      from invocation in Invocation,
        where:
          invocation.status not in @terminal_statuses and
            invocation.status != :deferred_capacity

    query =
      if excluded_invocation_id do
        where(query, [invocation], invocation.id != ^excluded_invocation_id)
      else
        query
      end

    Repo.aggregate(query, :count)
  end

  defp validate_thread_job!(%Changeset{valid?: true} = changeset, invocation) do
    worker = Changeset.get_field(changeset, :worker)
    queue = Changeset.get_field(changeset, :queue)
    args = Changeset.get_field(changeset, :args)

    if worker == @thread_worker and queue == "thread" and
         args == %{
           "uri" => invocation.invocation_uri,
           "cid" => invocation.notification_cid
         } do
      :ok
    else
      raise ArgumentError, "admission requires a valid ThreadWorker job on the thread queue"
    end
  end

  defp validate_thread_job!(_changeset, _invocation) do
    raise ArgumentError, "admission requires a valid ThreadWorker job on the thread queue"
  end
end
