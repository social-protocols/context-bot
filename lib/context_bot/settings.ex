defmodule ContextBot.Settings do
  @moduledoc """
  Validated, non-secret runtime settings for the Context Bot workflow.
  """

  @default_thread_parent_height 80
  @default_actor_hourly_limit 2
  @default_actor_daily_limit 5
  @default_global_hourly_limit 10
  @default_global_daily_limit 50
  @default_max_pending 25
  @default_queue_concurrency 1
  @default_max_response_bytes 8_000_000
  @default_max_storage_bytes 64_000_000

  @skywatch_did "did:plc:e4elbtctnfqocyfcml6h2lf7"
  @appview_url "https://api.bsky.app"
  @elder_label "bluesky-elder"

  @enforce_keys [
    :bot_enabled,
    :thread_parent_height,
    :actor_hourly_limit,
    :actor_daily_limit,
    :global_hourly_limit,
    :global_daily_limit,
    :max_pending,
    :queue_concurrency,
    :max_response_bytes,
    :max_storage_bytes,
    :operator_allowed_dids,
    :skywatch_did,
    :appview_url,
    :elder_label
  ]
  defstruct [
    :bot_enabled,
    :bot_did,
    :bot_handle,
    :bot_pds_url,
    :anthropic_daily_budget_usd,
    :thread_parent_height,
    :actor_hourly_limit,
    :actor_daily_limit,
    :global_hourly_limit,
    :global_daily_limit,
    :max_pending,
    :queue_concurrency,
    :max_response_bytes,
    :max_storage_bytes,
    :operator_allowed_dids,
    :skywatch_did,
    :appview_url,
    :elder_label
  ]

  @type t :: %__MODULE__{
          bot_enabled: boolean(),
          bot_did: String.t() | nil,
          bot_handle: String.t() | nil,
          bot_pds_url: String.t() | nil,
          anthropic_daily_budget_usd: String.t() | nil,
          thread_parent_height: pos_integer(),
          actor_hourly_limit: pos_integer(),
          actor_daily_limit: pos_integer(),
          global_hourly_limit: pos_integer(),
          global_daily_limit: pos_integer(),
          max_pending: pos_integer(),
          queue_concurrency: pos_integer(),
          max_response_bytes: pos_integer(),
          max_storage_bytes: pos_integer(),
          operator_allowed_dids: [String.t()],
          skywatch_did: String.t(),
          appview_url: String.t(),
          elder_label: String.t()
        }

  @spec load(
          keyword()
          | %{optional(String.t() | atom()) => String.t() | boolean() | integer() | nil}
        ) :: t()
  def load(environment) do
    settings = %__MODULE__{
      bot_enabled: boolean!(environment, "BOT_ENABLED", :bot_enabled, false),
      bot_did: optional_string(environment, "BOT_DID", :bot_did),
      bot_handle: optional_string(environment, "BOT_HANDLE", :bot_handle),
      bot_pds_url: optional_url(environment, "BOT_PDS_URL", :bot_pds_url),
      anthropic_daily_budget_usd:
        optional_decimal(environment, "ANTHROPIC_DAILY_BUDGET_USD", :anthropic_daily_budget_usd),
      thread_parent_height:
        positive_integer!(
          environment,
          "THREAD_PARENT_HEIGHT",
          :thread_parent_height,
          @default_thread_parent_height
        ),
      actor_hourly_limit:
        positive_integer!(
          environment,
          "ACTOR_HOURLY_LIMIT",
          :actor_hourly_limit,
          @default_actor_hourly_limit
        ),
      actor_daily_limit:
        positive_integer!(
          environment,
          "ACTOR_DAILY_LIMIT",
          :actor_daily_limit,
          @default_actor_daily_limit
        ),
      global_hourly_limit:
        positive_integer!(
          environment,
          "GLOBAL_HOURLY_LIMIT",
          :global_hourly_limit,
          @default_global_hourly_limit
        ),
      global_daily_limit:
        positive_integer!(
          environment,
          "GLOBAL_DAILY_LIMIT",
          :global_daily_limit,
          @default_global_daily_limit
        ),
      max_pending:
        positive_integer!(environment, "MAX_PENDING", :max_pending, @default_max_pending),
      queue_concurrency:
        positive_integer!(
          environment,
          "QUEUE_CONCURRENCY",
          :queue_concurrency,
          @default_queue_concurrency
        ),
      max_response_bytes:
        positive_integer!(
          environment,
          "ANTHROPIC_RESPONSE_MAX_BYTES",
          :anthropic_response_max_bytes,
          @default_max_response_bytes,
          [{"MAX_RESPONSE_BYTES", :max_response_bytes}]
        ),
      max_storage_bytes:
        positive_integer!(
          environment,
          "PROVIDER_RESPONSE_STORAGE_MAX_BYTES",
          :provider_response_storage_max_bytes,
          @default_max_storage_bytes,
          [{"MAX_STORAGE_BYTES", :max_storage_bytes}]
        ),
      operator_allowed_dids:
        did_list!(environment, "OPERATOR_ALLOWED_DIDS", :operator_allowed_dids, []),
      skywatch_did: @skywatch_did,
      appview_url: @appview_url,
      elder_label: @elder_label
    }

    validate!(settings)
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = settings) do
    validate_positive!(settings.thread_parent_height, "THREAD_PARENT_HEIGHT")
    validate_positive!(settings.actor_hourly_limit, "ACTOR_HOURLY_LIMIT")
    validate_positive!(settings.actor_daily_limit, "ACTOR_DAILY_LIMIT")
    validate_positive!(settings.global_hourly_limit, "GLOBAL_HOURLY_LIMIT")
    validate_positive!(settings.global_daily_limit, "GLOBAL_DAILY_LIMIT")
    validate_positive!(settings.max_pending, "MAX_PENDING")
    validate_positive!(settings.queue_concurrency, "QUEUE_CONCURRENCY")
    validate_positive!(settings.max_response_bytes, "MAX_RESPONSE_BYTES")
    validate_positive!(settings.max_storage_bytes, "MAX_STORAGE_BYTES")
    validate_optional_did!(settings.bot_did, "BOT_DID")
    validate_optional_url!(settings.bot_pds_url, "BOT_PDS_URL")
    validate_optional_decimal!(settings.anthropic_daily_budget_usd, "ANTHROPIC_DAILY_BUDGET_USD")

    if settings.max_storage_bytes <= settings.max_response_bytes do
      raise ArgumentError, "MAX_STORAGE_BYTES must be greater than MAX_RESPONSE_BYTES"
    end

    if settings.bot_enabled do
      require_did!(settings.bot_did, "BOT_DID")
      require_string!(settings.bot_handle, "BOT_HANDLE")
      require_url!(settings.bot_pds_url, "BOT_PDS_URL")
      require_decimal!(settings.anthropic_daily_budget_usd, "ANTHROPIC_DAILY_BUDGET_USD")
    end

    settings
  end

  @spec bot_enabled?(t()) :: boolean()
  def bot_enabled?(%__MODULE__{bot_enabled: bot_enabled}), do: bot_enabled

  defp boolean!(environment, environment_key, option_key, default) do
    case fetch(environment, environment_key, option_key, default) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> raise ArgumentError, "#{environment_key} must be true or false"
    end
  end

  defp positive_integer!(environment, environment_key, option_key, default, aliases \\ []) do
    environment
    |> fetch_first([{environment_key, option_key} | aliases], default)
    |> parse_positive_integer!(environment_key)
  end

  defp optional_decimal(environment, environment_key, option_key) do
    case fetch(environment, environment_key, option_key, nil) do
      nil -> nil
      value -> parse_decimal!(value, environment_key)
    end
  end

  defp optional_string(environment, environment_key, option_key) do
    case fetch(environment, environment_key, option_key, nil) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      _ -> raise ArgumentError, "#{environment_key} must be a string"
    end
  end

  defp optional_url(environment, environment_key, option_key) do
    environment
    |> optional_string(environment_key, option_key)
    |> case do
      nil -> nil
      value -> parse_url!(value, environment_key)
    end
  end

  defp did_list!(environment, environment_key, option_key, default) do
    case fetch(environment, environment_key, option_key, default) do
      values when is_list(values) ->
        Enum.each(values, &validate_did!(&1, environment_key))
        values

      values when is_binary(values) and values != "" ->
        parse_did_list!(values, environment_key)

      "" ->
        []

      _ ->
        raise ArgumentError, "#{environment_key} must be a comma-separated DID allowlist"
    end
  end

  defp parse_positive_integer!(value, _environment_key) when is_integer(value) and value > 0,
    do: value

  defp parse_positive_integer!(value, environment_key) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> raise ArgumentError, "#{environment_key} must be a positive integer"
    end
  end

  defp parse_positive_integer!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} must be a positive integer")

  defp parse_decimal!(value, environment_key) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9]\d*)(?:\.\d+)?\z/, value) and
         Decimal.compare(Decimal.new(value), 0) == :gt do
      value
    else
      raise ArgumentError, "#{environment_key} must be a positive decimal USD amount"
    end
  end

  defp parse_decimal!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} must be a positive decimal USD amount")

  defp parse_url!(value, environment_key) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        value

      _ ->
        raise ArgumentError,
              "#{environment_key} must be an HTTPS URL without credentials, query, or fragment"
    end
  end

  defp require_did!(value, environment_key) when is_binary(value) and value != "",
    do: validate_did!(value, environment_key)

  defp require_did!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} is required when BOT_ENABLED=true")

  defp require_string!(value, _environment_key) when is_binary(value) and value != "", do: value

  defp require_string!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} is required when BOT_ENABLED=true")

  defp require_url!(value, environment_key) when is_binary(value),
    do: parse_url!(value, environment_key)

  defp require_url!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} is required when BOT_ENABLED=true")

  defp require_decimal!(value, environment_key) when is_binary(value),
    do: parse_decimal!(value, environment_key)

  defp require_decimal!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} is required when BOT_ENABLED=true")

  defp validate_positive!(value, _environment_key) when is_integer(value) and value > 0, do: value

  defp validate_positive!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} must be a positive integer")

  defp validate_did!(did, environment_key) when is_binary(did) and did != "" do
    if Regex.match?(~r/\Adid:[a-z0-9]+:[A-Za-z0-9._:%-]+\z/, did) do
      did
    else
      raise ArgumentError, "#{environment_key} must contain exact DIDs"
    end
  end

  defp validate_did!(_did, environment_key),
    do: raise(ArgumentError, "#{environment_key} must contain exact DIDs")

  defp validate_optional_did!(nil, _environment_key), do: :ok
  defp validate_optional_did!(value, environment_key), do: validate_did!(value, environment_key)

  defp validate_optional_url!(nil, _environment_key), do: :ok
  defp validate_optional_url!(value, environment_key), do: parse_url!(value, environment_key)

  defp validate_optional_decimal!(nil, _environment_key), do: :ok

  defp validate_optional_decimal!(value, environment_key),
    do: parse_decimal!(value, environment_key)

  defp parse_did_list!(values, environment_key) do
    dids = String.split(values, ",", trim: true)

    if Enum.join(dids, ",") != values do
      raise ArgumentError, "#{environment_key} must be exact DIDs"
    end

    Enum.each(dids, &validate_did!(&1, environment_key))
    dids
  end

  defp fetch(environment, environment_key, option_key, default) when is_list(environment) do
    case Keyword.fetch(environment, option_key) do
      {:ok, value} ->
        value

      :error ->
        environment |> List.keyfind(environment_key, 0, {environment_key, default}) |> elem(1)
    end
  end

  defp fetch(environment, environment_key, option_key, default) when is_map(environment) do
    Map.get_lazy(environment, option_key, fn -> Map.get(environment, environment_key, default) end)
  end

  defp fetch_first(environment, keys, default) do
    Enum.find_value(keys, default, fn {environment_key, option_key} ->
      case fetch(environment, environment_key, option_key, :missing) do
        :missing -> nil
        value -> value
      end
    end)
  end
end
