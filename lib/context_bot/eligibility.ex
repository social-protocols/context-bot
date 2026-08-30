defmodule ContextBot.Eligibility do
  @moduledoc """
  Classifies an invocation actor into a rate-limit tier.

  Operator allowlist, a confirmed Skywatch Elder label, and a bidirectionally
  verified `bsky.team` handle remain privileged tiers. Everyone else is
  `:public`. Labeler or identity outages degrade to `:public` instead of
  rejecting the mention. All provider access is injected so the decision stays
  deterministic for a supplied clock.
  """

  alias ContextBot.Settings

  @type method :: :operator_allowlist | :bluesky_elder | :bsky_team | :public
  @type result :: {:eligible, method(), map()} | :ineligible | {:error, atom()}

  @spec check(String.t(), String.t() | nil, DateTime.t(), Settings.t(), module()) :: result()
  def check(actor_did, observed_handle, now, %Settings{} = settings, client)
      when is_binary(actor_did) and is_struct(now, DateTime) and is_atom(client) do
    if actor_did in settings.operator_allowed_dids do
      {:eligible, :operator_allowlist,
       %{"actor_did" => actor_did, "source" => "operator_allowlist"}}
    else
      check_elder(actor_did, observed_handle, now, settings, client)
    end
  end

  defp check_elder(actor_did, observed_handle, now, settings, client) do
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
          labels
        )

      {:ok, status, _headers, _body} when is_integer(status) ->
        team_or_public(actor_did, observed_handle, client)

      _error ->
        team_or_public(actor_did, observed_handle, client)
    end
  end

  defp evaluate_profile(actor_did, observed_handle, now, settings, client, headers, labels) do
    cond do
      not confirmed_labeler?(headers, settings.skywatch_did) ->
        team_or_public(actor_did, observed_handle, client)

      Enum.any?(labels, &active_elder_label?(&1, actor_did, now, settings)) ->
        {:eligible, :bluesky_elder,
         %{
           "actor_did" => actor_did,
           "label" => settings.elder_label,
           "labeler_did" => settings.skywatch_did
         }}

      true ->
        check_team(actor_did, observed_handle, client)
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
      public_eligible(actor_did)
    end
  end

  defp check_team(actor_did, _observed_handle, _client), do: public_eligible(actor_did)

  defp team_or_public(actor_did, observed_handle, client) do
    case check_team(actor_did, observed_handle, client) do
      {:eligible, :bsky_team, _evidence} = eligible -> eligible
      _not_independently_eligible -> public_eligible(actor_did)
    end
  end

  defp verify_forward_identity(actor_did, handle, client) do
    case client.resolve_handle(handle) do
      {:ok, status, _headers, %{"did" => ^actor_did}} when status in 200..299 ->
        if supported_did?(actor_did) do
          verify_did_document(actor_did, handle, client)
        else
          public_eligible(actor_did)
        end

      {:ok, status, _headers, %{"did" => resolved_did}}
      when status in 200..299 and is_binary(resolved_did) ->
        public_eligible(actor_did)

      {:ok, status, _headers, _body} when is_integer(status) ->
        public_eligible(actor_did)

      {:error, _reason} ->
        public_eligible(actor_did)
    end
  end

  defp verify_did_document(actor_did, handle, client) do
    case client.resolve_did(actor_did) do
      {:ok, status, _headers, body} when status in 200..299 ->
        verify_did_document_body(body, actor_did, handle)

      {:ok, status, _headers, _body} when is_integer(status) ->
        public_eligible(actor_did)

      {:error, _reason} ->
        public_eligible(actor_did)
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
      public_eligible(actor_did)
    end
  end

  defp verify_did_document_body(body, actor_did, _handle) when is_map(body),
    do: public_eligible(actor_did)

  defp verify_did_document_body(_body, actor_did, _handle), do: public_eligible(actor_did)

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

  defp public_eligible(actor_did) do
    {:eligible, :public, %{"actor_did" => actor_did, "source" => "public"}}
  end
end
