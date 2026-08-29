defmodule ContextBot.Eligibility do
  @moduledoc """
  Resolves the current, externally verifiable eligibility of an invocation actor.

  All provider access is injected so the decision stays deterministic for a supplied clock.
  """

  alias ContextBot.{Funding, Settings}

  @type method :: :operator_allowlist | :bluesky_elder | :bsky_team | :funded_handle
  @type result :: {:eligible, method(), map()} | :ineligible | {:error, atom()}

  @spec check(String.t(), String.t() | nil, DateTime.t(), Settings.t(), module(), map()) ::
          result()
  def check(actor_did, observed_handle, now, %Settings{} = settings, client, context \\ %{})
      when is_binary(actor_did) and is_struct(now, DateTime) and is_atom(client) and
             is_map(context) do
    if actor_did in settings.operator_allowed_dids do
      {:eligible, :operator_allowlist,
       %{"actor_did" => actor_did, "source" => "operator_allowlist"}}
    else
      check_elder(actor_did, observed_handle, now, settings, client, context)
    end
  end

  defp check_elder(actor_did, observed_handle, now, settings, client, context) do
    case client.get_profile(actor_did, settings.skywatch_did) do
      {:ok, status, headers, %{"labels" => labels}}
      when status in 200..299 and is_map(headers) and is_list(labels) ->
        evaluate_profile(
          actor_did,
          observed_handle,
          now,
          settings,
          client,
          headers,
          labels,
          context
        )

      {:ok, status, _headers, _body} when is_integer(status) ->
        team_or_funding(
          actor_did,
          observed_handle,
          settings,
          client,
          context,
          :labeler_unavailable
        )

      _error ->
        team_or_funding(
          actor_did,
          observed_handle,
          settings,
          client,
          context,
          :labeler_unavailable
        )
    end
  end

  defp evaluate_profile(
         actor_did,
         observed_handle,
         now,
         settings,
         client,
         headers,
         labels,
         context
       ) do
    cond do
      not confirmed_labeler?(headers, settings.skywatch_did) ->
        team_or_funding(
          actor_did,
          observed_handle,
          settings,
          client,
          context,
          :labeler_unavailable
        )

      Enum.any?(labels, &active_elder_label?(&1, actor_did, now, settings)) ->
        {:eligible, :bluesky_elder,
         %{
           "actor_did" => actor_did,
           "label" => settings.elder_label,
           "labeler_did" => settings.skywatch_did
         }}

      true ->
        check_team_or_funding(actor_did, observed_handle, settings, client, context)
    end
  end

  defp confirmed_labeler?(headers, labeler_did) do
    headers
    |> Map.get("atproto-content-labelers", [])
    |> List.wrap()
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(fn entry ->
      entry
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> Kernel.==(labeler_did)
    end)
  end

  defp active_elder_label?(label, actor_did, now, settings) when is_map(label) do
    label["src"] == settings.skywatch_did and
      label["uri"] == actor_did and
      label["val"] == settings.elder_label and
      label["neg"] in [nil, false] and
      active_at?(label["exp"], now)
  end

  defp active_elder_label?(_label, _actor_did, _now, _settings), do: false

  defp active_at?(nil, _now), do: true

  defp active_at?(expiration, now) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, expires_at, _offset} -> DateTime.after?(expires_at, now)
      _error -> false
    end
  end

  defp active_at?(_expiration, _now), do: false

  defp check_team(actor_did, observed_handle, client) when is_binary(observed_handle) do
    handle = String.downcase(observed_handle)

    if team_handle?(handle) do
      verify_forward_identity(actor_did, handle, client)
    else
      :ineligible
    end
  end

  defp check_team(_actor_did, _observed_handle, _client), do: :ineligible

  defp check_team_or_funding(actor_did, observed_handle, settings, client, context) do
    case check_team(actor_did, observed_handle, client) do
      {:eligible, :bsky_team, _evidence} = eligible ->
        eligible

      :ineligible ->
        check_funding(actor_did, observed_handle, settings, client, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp team_or_funding(actor_did, observed_handle, settings, client, context, fallback_error) do
    case check_team(actor_did, observed_handle, client) do
      {:eligible, :bsky_team, _evidence} = eligible ->
        eligible

      _not_independently_eligible ->
        case check_funding(actor_did, observed_handle, settings, client, context) do
          {:eligible, :funded_handle, _evidence} = eligible -> eligible
          :ineligible -> {:error, fallback_error}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp check_funding(actor_did, observed_handle, settings, client, context) do
    keys = settings.funding_keys

    if keys == [] do
      :ineligible
    else
      accounts =
        Funding.thread_accounts(context[:notification], actor_did, observed_handle)

      evaluate_funding(accounts, keys, settings, client, context)
    end
  end

  defp evaluate_funding([], _keys, _settings, _client, _context), do: :ineligible

  defp evaluate_funding(accounts, keys, settings, client, context) do
    with {:ok, resolved} <- resolve_funding_accounts(accounts, keys, settings, client) do
      chooser = context[:choose] || (&Enum.random/1)

      case Funding.select(resolved, keys, chooser) do
        {:ok, pick} ->
          {:eligible, :funded_handle,
           %{
             "fund_id" => pick.id,
             "handle" => pick.handle,
             "source" => "funded_handle"
           }}

        :none ->
          :ineligible
      end
    end
  end

  defp resolve_funding_accounts(accounts, keys, settings, client) do
    if Funding.needs_handles?(keys) and Enum.any?(accounts, &is_nil(&1.handle)) do
      Funding.resolve_handles(accounts, settings.skywatch_did, client)
    else
      {:ok, accounts}
    end
  end

  @spec payer_for(String.t(), String.t() | nil, Settings.t(), module(), map()) :: %{
          payer_kind: String.t(),
          payer_fund_id: String.t() | nil,
          payer_handle: String.t() | nil
        }
  def payer_for(actor_did, observed_handle, %Settings{} = settings, client, context \\ %{})
      when is_binary(actor_did) and is_atom(client) and is_map(context) do
    keys = settings.funding_keys
    accounts = Funding.thread_accounts(context[:notification], actor_did, observed_handle)

    cond do
      keys == [] or accounts == [] ->
        Funding.community_payer()

      true ->
        case resolve_funding_accounts(accounts, keys, settings, client) do
          {:ok, resolved} ->
            chooser = context[:choose] || (&Enum.random/1)
            Funding.payer_attrs(Funding.select(resolved, keys, chooser))

          {:error, _reason} ->
            Funding.community_payer()
        end
    end
  end

  defp verify_forward_identity(actor_did, handle, client) do
    case client.resolve_handle(handle) do
      {:ok, status, _headers, %{"did" => ^actor_did}} when status in 200..299 ->
        if supported_did?(actor_did) do
          verify_did_document(actor_did, handle, client)
        else
          :ineligible
        end

      {:ok, status, _headers, %{"did" => resolved_did}}
      when status in 200..299 and is_binary(resolved_did) ->
        :ineligible

      {:ok, status, _headers, _body} when is_integer(status) and status not in 200..299 ->
        {:error, :identity_unavailable}

      {:ok, status, _headers, _malformed_body} when status in 200..299 ->
        {:error, :identity_unavailable}

      {:error, _reason} ->
        {:error, :identity_unavailable}
    end
  end

  defp verify_did_document(actor_did, handle, client) do
    case client.resolve_did(actor_did) do
      {:ok, status, _headers, body} when status in 200..299 ->
        verify_did_document_body(body, actor_did, handle)

      {:ok, status, _headers, _body} when is_integer(status) and status not in 200..299 ->
        {:error, :identity_unavailable}

      {:error, _reason} ->
        {:error, :identity_unavailable}
    end
  end

  defp verify_did_document_body(
         %{"id" => actor_did, "alsoKnownAs" => aliases},
         actor_did,
         handle
       )
       when is_list(aliases) do
    if first_valid_handle_claim(aliases) == handle do
      {:eligible, :bsky_team,
       %{
         "actor_did" => actor_did,
         "handle" => handle,
         "verification" => "bidirectional"
       }}
    else
      :ineligible
    end
  end

  defp verify_did_document_body(body, _actor_did, _handle) when is_map(body), do: :ineligible

  defp verify_did_document_body(_body, _actor_did, _handle),
    do: {:error, :identity_unavailable}

  defp first_valid_handle_claim(aliases) do
    Enum.find_value(aliases, fn
      "at://" <> claimed_handle -> normalize_handle(claimed_handle)
      _other -> nil
    end)
  end

  defp normalize_handle(handle) do
    normalized = String.downcase(handle)
    if valid_handle?(normalized), do: normalized
  end

  defp team_handle?(handle) do
    valid_handle?(handle) and (handle == "bsky.team" or String.ends_with?(handle, ".bsky.team"))
  end

  defp valid_handle?(handle) do
    labels = String.split(handle, ".", trim: false)

    byte_size(handle) in 1..253 and
      length(labels) >= 2 and
      Enum.all?(labels, &valid_handle_label?/1) and
      Regex.match?(~r/[a-z]/, List.last(labels))
  end

  defp valid_handle_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, label)
  end

  defp supported_did?("did:plc:" <> identifier), do: identifier != ""
  defp supported_did?("did:web:" <> identifier), do: identifier != ""
  defp supported_did?(_did), do: false
end
