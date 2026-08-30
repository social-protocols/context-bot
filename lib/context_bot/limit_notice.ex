defmodule ContextBot.LimitNotice do
  @moduledoc """
  Posts one canned Bluesky reply when an actor or the shared research budget is exhausted.

  Actor-rate notices follow the image-limit capability pattern: freeze a reply intent and
  hand off to ReplyWorker, then terminalize. They never set `admitted_at` and never run
  research. Budget notices stay `deferred_budget` so UTC rollover can still research.
  """

  import Ecto.Query

  alias ContextBot.ATProto.{ATURI, ReqClient, TID}
  alias ContextBot.Reply.Intent
  alias ContextBot.Repo
  alias ContextBot.Research.ReplyLimits
  alias ContextBot.Workflow.{Invocation, Store}

  @homepage_url "https://context-bot-social-protocols.fly.dev"
  @collection "app.bsky.feed.post"
  @reply_worker "ContextBot.Workers.ReplyWorker"
  @notice_kinds [:actor_rate, :budget]

  @spec homepage_url() :: String.t()
  def homepage_url, do: @homepage_url

  @spec actor_rate_text(DateTime.t() | nil) :: String.t()
  def actor_rate_text(%DateTime{} = defer_until) do
    "You have reached today's limit for your tier. Try again after #{format_time(defer_until)}. #{@homepage_url}"
  end

  def actor_rate_text(nil) do
    "You have reached today's limit for your tier. Try again later. #{@homepage_url}"
  end

  @spec budget_text() :: String.t()
  def budget_text do
    "The shared daily research budget is used up. Try again after 00:00 UTC. #{@homepage_url}"
  end

  @doc """
  Freezes one actor-rate notice and hands it to ReplyWorker, or terminalizes silently.

  Global and capacity deferrals must not call this. The invocation stays off the
  admitted-at rate counters.
  """
  @spec handoff_actor_rate(Invocation.t(), map()) :: :ok
  def handoff_actor_rate(%Invocation{dry_run: true}, _deps), do: :ok

  def handoff_actor_rate(%Invocation{} = invocation, deps) do
    cond do
      skip_actor_rate_notice?(invocation, deps) ->
        silent_complete(invocation, now(deps))

      not publishable?(deps) ->
        silent_complete(invocation, now(deps))

      true ->
        freeze_actor_rate(invocation, deps)
    end
  end

  @doc """
  Posts one budget-exhaustion notice and stays `deferred_budget`.

  The admission slot is already consumed. A later UTC rollover can still research.
  """
  @spec maybe_post_budget(Invocation.t(), map()) :: :ok
  def maybe_post_budget(%Invocation{dry_run: true}, _deps), do: :ok

  def maybe_post_budget(%Invocation{} = invocation, deps) do
    cond do
      parent_by_bot?(invocation, deps) ->
        :ok

      not publishable?(deps) ->
        :ok

      true ->
        post_budget(invocation, deps)
    end
  end

  defp freeze_actor_rate(invocation, deps) do
    created_at = now(deps)
    text = actor_rate_text(invocation.defer_until)

    with :ok <- validate_copy(text),
         {:ok, intent} <- build_intent(deps, invocation, text, created_at) do
      attrs = notice_reply_attrs(text, "actor_rate", intent, created_at)

      case Store.transition(
             invocation,
             :deferred_rate,
             :reply_ready,
             attrs,
             reply_job(deps, invocation)
           ) do
        {:ok, _ready} ->
          :ok

        {:error, :stale_stage} ->
          :ok

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
      end
    else
      {:error, _reason} ->
        fail_closed(invocation, created_at)
    end
  end

  defp post_budget(invocation, deps) do
    created_at = now(deps)
    text = budget_text()

    case Store.claim_limit_notice(invocation, :budget) do
      {:ok, claimed} ->
        persist_budget_notice(claimed, deps, text, created_at)

      {:error, reason} when reason in [:already_claimed, :dry_run, :stale_stage] ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp persist_budget_notice(invocation, deps, text, created_at) do
    with :ok <- validate_copy(text),
         {:ok, intent} <- build_intent(deps, invocation, text, created_at),
         {:ok, uri, cid} <- put_notice(deps, intent) do
      case Store.record_limit_notice(invocation, uri, cid, created_at) do
        {:ok, _recorded} ->
          :ok

        {:error, :stale_stage} ->
          :ok

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
      end
    else
      {:error, _reason} ->
        :ok
    end
  end

  defp put_notice(deps, intent) do
    case client(deps).put_record(
           intent.reply_repo,
           @collection,
           intent.reply_rkey,
           intent.reply_record
         ) do
      {:ok, status, _headers, %{"uri" => uri, "cid" => cid}}
      when status in 200..299 and is_binary(uri) and is_binary(cid) and cid != "" ->
        {:ok, uri, cid}

      _failure ->
        {:error, :notice_put_failed}
    end
  end

  defp notice_reply_attrs(text, reason, intent, _created_at) do
    %{
      selected_reply: text,
      reply_validation: %{
        "result" => "limit_notice",
        "reason" => reason,
        "source" => "local"
      },
      full_response: nil,
      anthropic_messages: nil,
      anthropic_usage: zero_usage(),
      reply_repo: intent.reply_repo,
      reply_rkey: intent.reply_rkey,
      reply_record: intent.reply_record,
      limit_notice_kind: :actor_rate,
      admitted_at: nil,
      completed_at: nil,
      failure_category: nil,
      failure_detail: nil
    }
  end

  defp silent_complete(invocation, completed_at) do
    case Store.transition(
           invocation,
           :deferred_rate,
           :complete,
           %{
             completed_at: completed_at,
             admitted_at: nil,
             selected_reply: nil,
             reply_record: nil,
             reply_rkey: nil,
             reply_repo: nil
           },
           nil
         ) do
      {:ok, _complete} ->
        :ok

      {:error, :stale_stage} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp fail_closed(invocation, completed_at) do
    case Store.transition(
           invocation,
           :deferred_rate,
           :failed,
           %{
             failure_category: :publication_conflict,
             failure_detail: %{"reason" => "limit_notice_intent"},
             completed_at: completed_at,
             admitted_at: nil
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

  defp skip_actor_rate_notice?(invocation, deps) do
    parent_by_bot?(invocation, deps) or actor_noticed_in_window?(invocation, now(deps))
  end

  defp parent_by_bot?(invocation, deps) do
    bot_did = deps.settings.bot_did

    case {bot_did, parent_uri(invocation)} do
      {did, uri} when is_binary(did) and is_binary(uri) ->
        case ATURI.parse(uri) do
          {:ok, %{repo: ^did}} -> true
          _other -> false
        end

      _missing ->
        false
    end
  end

  defp parent_uri(%Invocation{
         raw_notification: %{"record" => %{"reply" => %{"parent" => parent}}}
       })
       when is_map(parent) do
    case Map.get(parent, "uri") || Map.get(parent, :uri) do
      uri when is_binary(uri) and uri != "" -> uri
      _missing -> nil
    end
  end

  defp parent_uri(_invocation), do: nil

  defp actor_noticed_in_window?(%Invocation{id: id, actor_did: actor_did}, %DateTime{} = now) do
    cutoff = DateTime.add(now, -24 * 60 * 60, :second)

    Repo.exists?(
      from invocation in Invocation,
        where:
          invocation.actor_did == ^actor_did and
            invocation.id != ^id and
            invocation.limit_notice_kind in ^@notice_kinds and
            (invocation.limit_notice_posted_at > ^cutoff or
               (is_nil(invocation.limit_notice_posted_at) and invocation.inserted_at > ^cutoff))
    )
  end

  defp publishable?(%{settings: %{bot_did: bot_did}})
       when is_binary(bot_did) and bot_did != "",
       do: true

  defp publishable?(_deps), do: false

  defp validate_copy(text) do
    if ReplyLimits.fits_one_post?(text) and not String.contains?(text, "@") do
      :ok
    else
      {:error, :invalid_notice_copy}
    end
  end

  defp build_intent(deps, invocation, text, created_at) do
    builder = Map.get(deps, :intent_builder, &Intent.build/5)
    tid = Map.get(deps, :tid_generator, &TID.generate/1)
    bot_did = deps.settings.bot_did

    cond do
      is_function(builder, 5) ->
        builder.(invocation, text, bot_did, created_at, tid)

      is_function(builder, 6) ->
        builder.(invocation, text, bot_did, created_at, tid, [])

      true ->
        Intent.build(invocation, text, bot_did, created_at, tid)
    end
  end

  defp reply_job(deps, invocation) do
    builder = Map.get(deps, :reply_job_builder, &default_reply_job/1)
    builder.(invocation)
  end

  defp default_reply_job(invocation) do
    Oban.Job.new(
      %{"uri" => invocation.invocation_uri, "cid" => invocation.notification_cid},
      worker: @reply_worker,
      queue: :reply
    )
  end

  defp client(deps), do: Map.get(deps, :atproto_client) || Map.get(deps, :client) || ReqClient

  defp now(%{now: %DateTime{} = now}), do: now
  defp now(%{now: fun}) when is_function(fun, 0), do: fun.()
  defp now(_deps), do: DateTime.utc_now()

  defp format_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
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
end
