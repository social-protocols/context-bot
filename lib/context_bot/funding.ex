defmodule ContextBot.Funding do
  @moduledoc """
  Operator-curated funding keys: handle/DID patterns and optional BYO Anthropic credentials.

  Settings store only opaque fund ids and patterns. API keys live in application env
  and are never copied onto invocations, pages, or logs.
  """

  alias ContextBot.ATProto.ATURI

  @type key :: %{id: String.t(), patterns: [String.t()]}
  @type account :: %{did: String.t() | nil, handle: String.t() | nil}
  @type pick :: %{id: String.t(), handle: String.t() | nil, did: String.t() | nil}

  @did_regex ~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/
  @fund_id_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @doc "Anthropic API key for a fund, or the operator key when the fund has none."
  @spec credential(String.t() | nil) :: String.t()
  def credential(fund_id) do
    case fund_secret(fund_id) do
      key when is_binary(key) and key != "" -> key
      _missing -> operator_credential()
    end
  end

  @doc false
  @spec fund_secret(String.t() | nil) :: String.t() | nil
  def fund_secret(fund_id) when is_binary(fund_id) and fund_id != "" do
    case Application.get_env(:context_bot, :funding_api_keys, %{}) do
      %{^fund_id => key} when is_binary(key) and key != "" -> key
      _missing -> nil
    end
  end

  def fund_secret(_fund_id), do: nil

  @spec operator_credential() :: String.t()
  def operator_credential, do: Application.fetch_env!(:context_bot, :anthropic_api_key)

  @spec env_secret_name(String.t()) :: String.t()
  def env_secret_name(fund_id) when is_binary(fund_id) do
    "FUNDING_KEY_" <> String.replace(String.upcase(fund_id), "-", "_") <> "_ANTHROPIC_API_KEY"
  end

  @spec load_secrets(Enumerable.t(), %{optional(String.t()) => String.t() | nil}) :: %{
          optional(String.t()) => String.t()
        }
  def load_secrets(keys, environment) when is_map(environment) do
    Enum.reduce(keys, %{}, fn key, acc ->
      name = env_secret_name(key.id)

      case Map.get(environment, name) do
        value when is_binary(value) and value != "" -> Map.put(acc, key.id, value)
        _missing -> acc
      end
    end)
  end

  @spec valid_fund_id?(String.t()) :: boolean()
  def valid_fund_id?(id) when is_binary(id), do: Regex.match?(@fund_id_regex, id)
  def valid_fund_id?(_id), do: false

  @spec normalize_pattern!(String.t(), String.t()) :: String.t()
  def normalize_pattern!(pattern, environment_key) when is_binary(pattern) do
    cond do
      pattern == "*" ->
        "*"

      String.starts_with?(pattern, "*.") ->
        suffix = String.downcase(String.trim_leading(pattern, "*."))

        if suffix != "" and not String.contains?(suffix, "*") and valid_handle?(suffix) do
          "*." <> suffix
        else
          raise ArgumentError, "#{environment_key} contains an invalid glob"
        end

      Regex.match?(@did_regex, pattern) ->
        pattern

      true ->
        handle = String.downcase(pattern)

        if valid_handle?(handle) do
          handle
        else
          raise ArgumentError, "#{environment_key} contains an invalid handle or DID pattern"
        end
    end
  end

  def normalize_pattern!(_pattern, environment_key),
    do: raise(ArgumentError, "#{environment_key} contains an invalid handle or DID pattern")

  @spec thread_accounts(map() | nil, String.t() | nil, String.t() | nil) :: [account()]
  def thread_accounts(notification, actor_did, actor_handle) do
    case reply_refs(notification) do
      :none ->
        wrap_account(actor_did, normalize_handle(actor_handle))

      {:ok, reply} ->
        []
        |> maybe_add_ref(reply["parent"])
        |> maybe_add_ref(reply["root"])
    end
  end

  @spec resolve_handles([account()], String.t(), module()) ::
          {:ok, [account()]} | {:error, atom()}
  def resolve_handles(accounts, labeler_did, client)
      when is_list(accounts) and is_binary(labeler_did) do
    Enum.reduce_while(accounts, {:ok, []}, fn account, {:ok, resolved} ->
      case ensure_handle(account, labeler_did, client) do
        {:ok, complete} -> {:cont, {:ok, resolved ++ [complete]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec needs_handles?([key()]) :: boolean()
  def needs_handles?(keys) when is_list(keys) do
    Enum.any?(keys, fn key ->
      Enum.any?(key.patterns, fn
        "did:" <> _ -> false
        _pattern -> true
      end)
    end)
  end

  @spec matching_keys([key()], [account()]) :: [key()]
  def matching_keys(keys, accounts) when is_list(keys) and is_list(accounts) do
    Enum.filter(keys, fn key -> Enum.any?(accounts, &matches_key?(key, &1)) end)
  end

  @spec select([account()], [key()], ([key()] -> key())) :: {:ok, pick()} | :none
  def select(accounts, keys, chooser \\ &Enum.random/1)
      when is_list(accounts) and is_list(keys) and is_function(chooser, 1) do
    case matching_keys(keys, accounts) do
      [] ->
        :none

      [key] ->
        {:ok, pick(key, accounts)}

      many ->
        {:ok, pick(chooser.(many), accounts)}
    end
  end

  @spec payer_attrs(pick() | :none | {:ok, pick()}) :: %{
          payer_kind: String.t(),
          payer_fund_id: String.t() | nil,
          payer_handle: String.t() | nil
        }
  def payer_attrs({:ok, pick}), do: payer_attrs(pick)

  def payer_attrs(%{id: id} = pick) when is_binary(id) do
    %{
      payer_kind: "funded_handle",
      payer_fund_id: id,
      payer_handle: pick.handle
    }
  end

  def payer_attrs(_none) do
    %{payer_kind: "community_pot", payer_fund_id: nil, payer_handle: nil}
  end

  @spec community_payer() :: %{
          payer_kind: String.t(),
          payer_fund_id: nil,
          payer_handle: nil
        }
  def community_payer, do: payer_attrs(:none)

  defp pick(key, accounts) do
    account = Enum.find(accounts, &matches_key?(key, &1))

    %{
      id: key.id,
      handle: account && normalize_handle(account.handle),
      did: account && account.did
    }
  end

  defp matches_key?(key, account) do
    Enum.any?(key.patterns, &pattern_matches?(&1, account))
  end

  defp pattern_matches?("*", %{handle: handle}) when is_binary(handle) and handle != "", do: true

  defp pattern_matches?("*." <> suffix, %{handle: handle}) when is_binary(handle) do
    handle = String.downcase(handle)
    handle != suffix and String.ends_with?(handle, "." <> suffix)
  end

  defp pattern_matches?("did:" <> _ = did, %{did: account_did}) when is_binary(account_did),
    do: did == account_did

  defp pattern_matches?(exact, %{handle: handle}) when is_binary(handle),
    do: exact == String.downcase(handle)

  defp pattern_matches?(_pattern, _account), do: false

  defp ensure_handle(%{handle: handle} = account, _labeler_did, _client)
       when is_binary(handle) and handle != "",
       do: {:ok, account}

  defp ensure_handle(%{did: did} = account, labeler_did, client)
       when is_binary(did) and is_binary(labeler_did) do
    case client.get_profile(did, labeler_did) do
      {:ok, status, _headers, body} when status in 200..299 ->
        {:ok, assign_handle(account, profile_handle(body))}

      {:ok, status, _headers, _body} when is_integer(status) ->
        {:error, :identity_unavailable}

      _error ->
        {:error, :identity_unavailable}
    end
  end

  defp ensure_handle(account, _labeler_did, _client), do: {:ok, account}

  defp assign_handle(account, handle) do
    case normalize_handle(handle) do
      normalized when is_binary(normalized) -> %{account | handle: normalized}
      nil -> account
    end
  end

  defp profile_handle(%{"handle" => handle}), do: handle
  defp profile_handle(_body), do: nil

  defp reply_refs(%{"record" => %{"reply" => reply}}) when is_map(reply), do: {:ok, reply}
  defp reply_refs(_notification), do: :none

  defp maybe_add_ref(accounts, %{"uri" => uri}) when is_binary(uri) do
    case ATURI.parse(uri) do
      {:ok, %{repo: did}} -> accounts ++ wrap_account(did, nil)
      :error -> accounts
    end
  end

  defp maybe_add_ref(accounts, _ref), do: accounts

  defp wrap_account(did, handle) when is_binary(did) and did != "",
    do: [%{did: did, handle: handle}]

  defp wrap_account(_did, _handle), do: []

  defp normalize_handle(handle) when is_binary(handle) do
    normalized = String.downcase(handle)
    if valid_handle?(normalized), do: normalized
  end

  defp normalize_handle(_handle), do: nil

  defp valid_handle?(handle) when is_binary(handle) do
    labels = String.split(handle, ".", trim: false)

    byte_size(handle) in 1..253 and
      length(labels) >= 2 and
      Enum.all?(labels, &valid_handle_label?/1) and
      Regex.match?(~r/[a-z]/, List.last(labels))
  end

  defp valid_handle?(_handle), do: false

  defp valid_handle_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, label)
  end
end
