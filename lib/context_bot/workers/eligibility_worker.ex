defmodule ContextBot.Workers.EligibilityWorker do
  @moduledoc """
  Rechecks current actor eligibility before atomically attempting admission.

  Provider calls happen only after the invocation owns the resumable
  `checking_eligibility` checkpoint. Admission alone may enqueue thread capture.
  """

  use Oban.Worker, queue: :eligibility, max_attempts: 10

  import Ecto.Query

  alias ContextBot.{Admission, Eligibility, Funding, Operations, Repo}
  alias ContextBot.ATProto.ReqClient
  alias ContextBot.Workflow.{Invocation, Store}

  @thread_worker "ContextBot.Workers.ThreadWorker"
  @evidence_value_max_bytes 256

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri, "cid" => cid}} = job)
      when is_binary(uri) and is_binary(cid) do
    case find_invocation(uri, cid) do
      nil -> :ok
      invocation -> process_invocation(invocation, job, dependencies())
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

  defp process_invocation(invocation, job, dependencies) do
    case claim(invocation) do
      {:ok, claimed} -> logged_check(claimed, job, dependencies)
      :ignore -> :ok
    end
  end

  defp logged_check(invocation, job, dependencies) do
    started_at = System.monotonic_time(:millisecond)
    result = check_eligibility(invocation, dependencies)

    Operations.log_attempt(invocation,
      attempt_kind: :eligibility,
      attempt_index: job.attempt,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      failure_category: eligibility_failure(result)
    )

    result
  end

  defp eligibility_failure({:error, _reason}), do: :identity_unavailable
  defp eligibility_failure(_result), do: nil

  defp claim(%Invocation{stage: :checking_eligibility} = invocation),
    do: {:ok, invocation}

  defp claim(%Invocation{stage: stage} = invocation)
       when stage in [:received, :deferred_rate] do
    case Store.transition(
           invocation,
           stage,
           :checking_eligibility,
           %{eligibility_method: nil, eligibility_evidence: nil, defer_until: nil},
           nil
         ) do
      {:ok, claimed} ->
        {:ok, claimed}

      {:error, :stale_stage} ->
        :ignore

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp claim(%Invocation{}), do: :ignore

  defp check_eligibility(invocation, dependencies) do
    context = %{notification: invocation.raw_notification}

    result =
      dependencies.eligibility.check(
        invocation.actor_did,
        invocation.actor_handle,
        dependencies.now,
        dependencies.settings,
        dependencies.client,
        context
      )

    handle_eligibility(result, invocation, dependencies, context)
  end

  defp handle_eligibility({:eligible, method, evidence}, invocation, dependencies, context) do
    admission = dependencies.admission
    payer = payer_attrs(method, evidence, invocation, dependencies, context)

    case Store.transition(
           invocation,
           :checking_eligibility,
           :checking_eligibility,
           Map.merge(
             %{
               eligibility_method: Atom.to_string(method),
               eligibility_evidence: safe_evidence(method, evidence),
               defer_until: nil
             },
             payer
           ),
           nil
         ) do
      {:ok, evidenced} ->
        evidenced
        |> admission.admit(
          dependencies.now,
          dependencies.settings,
          thread_job(evidenced)
        )
        |> admission_result()

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp handle_eligibility(:ineligible, invocation, dependencies, _context) do
    case Store.transition(
           invocation,
           :checking_eligibility,
           :ineligible,
           Map.merge(
             %{
               eligibility_method: nil,
               eligibility_evidence: %{"result" => "ineligible"},
               defer_until: nil,
               completed_at: dependencies.now
             },
             %{payer_kind: nil, payer_fund_id: nil, payer_handle: nil}
           ),
           nil
         ) do
      {:ok, _ineligible} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp handle_eligibility({:error, reason}, invocation, _dependencies, _context)
       when is_atom(reason) do
    case Store.transition(
           invocation,
           :checking_eligibility,
           :checking_eligibility,
           %{
             eligibility_method: nil,
             eligibility_evidence: %{
               "reason" => Atom.to_string(reason),
               "result" => "lookup_unavailable"
             }
           },
           nil
         ) do
      {:ok, _checkpoint} ->
        {:error, reason}

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp admission_result({:ok, _invocation}), do: :ok
  defp admission_result({:deferred, _reason, _invocation}), do: :ok

  defp thread_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @thread_worker,
      queue: :thread
    )
  end

  defp safe_evidence(method, evidence) when is_map(evidence) do
    method
    |> evidence_keys()
    |> Enum.reduce(%{}, fn key, safe ->
      case fetch(evidence, key) do
        value when is_binary(value) -> Map.put(safe, key, bound_binary(value))
        value when is_boolean(value) or is_number(value) -> Map.put(safe, key, value)
        _missing_or_unsafe -> safe
      end
    end)
  end

  defp safe_evidence(_method, _evidence), do: %{}

  defp evidence_keys(:operator_allowlist), do: ["actor_did", "source"]
  defp evidence_keys(:bluesky_elder), do: ["actor_did", "label", "labeler_did"]
  defp evidence_keys(:bsky_team), do: ["actor_did", "handle", "verification"]
  defp evidence_keys(:funded_handle), do: ["fund_id", "handle", "source"]
  defp evidence_keys(_method), do: []

  defp fetch(map, "actor_did"), do: fetch_key(map, "actor_did", :actor_did)
  defp fetch(map, "source"), do: fetch_key(map, "source", :source)
  defp fetch(map, "label"), do: fetch_key(map, "label", :label)
  defp fetch(map, "labeler_did"), do: fetch_key(map, "labeler_did", :labeler_did)
  defp fetch(map, "handle"), do: fetch_key(map, "handle", :handle)
  defp fetch(map, "verification"), do: fetch_key(map, "verification", :verification)
  defp fetch(map, "fund_id"), do: fetch_key(map, "fund_id", :fund_id)

  defp payer_attrs(:funded_handle, evidence, _invocation, _dependencies, _context) do
    %{
      payer_kind: "funded_handle",
      payer_fund_id: fetch(evidence, "fund_id"),
      payer_handle: fetch(evidence, "handle")
    }
  end

  defp payer_attrs(_method, _evidence, invocation, dependencies, context) do
    eligibility = dependencies.eligibility

    if function_exported?(eligibility, :payer_for, 5) do
      eligibility.payer_for(
        invocation.actor_did,
        invocation.actor_handle,
        dependencies.settings,
        dependencies.client,
        context
      )
    else
      Funding.community_payer()
    end
  end

  defp fetch_key(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp bound_binary(value) do
    if String.valid?(value) do
      value
      |> take_graphemes([], 0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    else
      ""
    end
  end

  defp take_graphemes("", graphemes, _size), do: graphemes

  defp take_graphemes(value, graphemes, size) do
    {grapheme, rest} = String.next_grapheme(value)
    next_size = size + byte_size(grapheme)

    if next_size <= @evidence_value_max_bytes do
      take_graphemes(rest, [grapheme | graphemes], next_size)
    else
      graphemes
    end
  end

  defp dependencies do
    config = Application.get_env(:context_bot, __MODULE__, [])

    %{
      admission: Keyword.get(config, :admission, Admission),
      client: Keyword.get(config, :client, ReqClient),
      eligibility: Keyword.get(config, :eligibility, Eligibility),
      now: Keyword.get(config, :now, DateTime.utc_now()),
      settings: Keyword.get(config, :settings, Application.fetch_env!(:context_bot, :settings))
    }
  end
end
