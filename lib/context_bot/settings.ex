defmodule ContextBot.Settings do
  @moduledoc """
  Validated, non-secret runtime settings for the Context Bot workflow.
  """

  alias ContextBot.Money
  alias ContextBot.Research.{Pricing, ResponseEnvelope}

  @default_thread_parent_height 80
  @default_actor_hourly_limit 2
  @default_actor_daily_limit 5
  @default_actor_daily_limit_public 1
  @default_global_hourly_limit 10
  @default_global_daily_limit 50
  @default_max_pending 25
  @default_queue_concurrency 1
  @default_appview_url "https://api.bsky.app"
  @default_poll_interval_ms 30_000
  @default_notification_page_cap 5
  @minimum_poll_interval_ms 5_000
  @maximum_poll_interval_ms 3_600_000
  @maximum_notification_page_cap 20
  @default_atproto_http_timeout_ms 15_000
  @default_atproto_session_timeout_ms 15_000
  @default_thread_fetch_timeout_ms 20_000
  @default_max_response_bytes 8_000_000
  @default_max_storage_bytes 64_000_000
  @default_anthropic_http_timeout_ms 300_000
  @default_anthropic_api_version "2023-06-01"
  @default_anthropic_web_search_tool_type "web_search_20260318"
  @default_anthropic_web_fetch_tool_type "web_fetch_20260318"
  @default_anthropic_effort :medium
  @default_anthropic_research_max_tokens 8_192
  @default_anthropic_length_repair_max_tokens 1_024
  @default_anthropic_structure_max_tokens 1_024
  @default_anthropic_structure_reservation_usd "0.500000"
  @default_anthropic_model_id "claude-sonnet-5"
  @default_anthropic_title_model_id "claude-haiku-4-5"
  @default_max_web_search_uses 5
  @default_max_web_fetch_uses 8
  @default_max_web_fetch_content_tokens 10_000
  @default_max_tool_continuations 1
  @default_anthropic_max_http_retries 2
  @default_anthropic_retry_base_ms 1_000
  @default_anthropic_retry_max_ms 30_000
  @default_anthropic_reservation_usd "5.000000"
  @default_anthropic_pricing_version "sonnet-5-2026-07-28"

  @maximum_atproto_timeout_ms 60_000
  @maximum_anthropic_timeout_ms 600_000
  # Fly kill_timeout max is 300s. Anthropic HTTP may use the same window.
  @fly_max_kill_timeout_ms 300_000
  @drain_grace_buffer_ms 15_000
  @maximum_thread_parent_height 100
  @maximum_anthropic_research_tokens 64_000
  @maximum_anthropic_repair_tokens 8_192
  @maximum_web_tool_uses 10
  @maximum_web_fetch_content_tokens 100_000
  @maximum_tool_continuations 5
  @maximum_anthropic_http_retries 3
  @maximum_anthropic_retry_base_ms 60_000
  @maximum_anthropic_retry_max_ms 300_000
  @maximum_response_bytes 16_000_000
  @maximum_storage_bytes 128_000_000

  @skywatch_did "did:plc:e4elbtctnfqocyfcml6h2lf7"
  @elder_label "bluesky-elder"

  @enforce_keys [
    :bot_enabled,
    :appview_url,
    :poll_interval_ms,
    :notification_page_cap,
    :atproto_http_timeout_ms,
    :atproto_session_timeout_ms,
    :thread_fetch_timeout_ms,
    :thread_parent_height,
    :actor_hourly_limit,
    :actor_daily_limit,
    :actor_daily_limit_public,
    :global_hourly_limit,
    :global_daily_limit,
    :max_pending,
    :queue_concurrency,
    :max_response_bytes,
    :max_storage_bytes,
    :anthropic_model_id,
    :anthropic_title_model_id,
    :anthropic_effort,
    :anthropic_http_timeout_ms,
    :anthropic_api_version,
    :anthropic_web_search_tool_type,
    :anthropic_web_fetch_tool_type,
    :anthropic_research_max_tokens,
    :anthropic_length_repair_max_tokens,
    :anthropic_structure_model_id,
    :anthropic_structure_max_tokens,
    :max_web_search_uses,
    :max_web_fetch_uses,
    :max_web_fetch_content_tokens,
    :max_tool_continuations,
    :anthropic_max_http_retries,
    :anthropic_retry_base_ms,
    :anthropic_retry_max_ms,
    :anthropic_research_reservation_microdollars,
    :anthropic_continuation_reservation_microdollars,
    :anthropic_repair_reservation_microdollars,
    :anthropic_structure_reservation_microdollars,
    :anthropic_retry_reservation_microdollars,
    :anthropic_pricing_version,
    :operator_allowed_dids,
    :skywatch_did,
    :elder_label
  ]
  # The workflow settings intentionally stay in one validated startup snapshot.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :bot_enabled,
    :bot_did,
    :bot_handle,
    :bot_pds_url,
    :appview_url,
    :poll_interval_ms,
    :notification_page_cap,
    :atproto_http_timeout_ms,
    :atproto_session_timeout_ms,
    :thread_fetch_timeout_ms,
    :anthropic_daily_budget_microdollars,
    :anthropic_model_id,
    :anthropic_title_model_id,
    :anthropic_effort,
    :anthropic_http_timeout_ms,
    :anthropic_api_version,
    :anthropic_web_search_tool_type,
    :anthropic_web_fetch_tool_type,
    :anthropic_research_max_tokens,
    :anthropic_length_repair_max_tokens,
    :anthropic_structure_model_id,
    :anthropic_structure_max_tokens,
    :max_web_search_uses,
    :max_web_fetch_uses,
    :max_web_fetch_content_tokens,
    :max_tool_continuations,
    :anthropic_max_http_retries,
    :anthropic_retry_base_ms,
    :anthropic_retry_max_ms,
    :anthropic_research_reservation_microdollars,
    :anthropic_continuation_reservation_microdollars,
    :anthropic_repair_reservation_microdollars,
    :anthropic_structure_reservation_microdollars,
    :anthropic_retry_reservation_microdollars,
    :anthropic_pricing_version,
    :thread_parent_height,
    :actor_hourly_limit,
    :actor_daily_limit,
    :actor_daily_limit_public,
    :global_hourly_limit,
    :global_daily_limit,
    :max_pending,
    :queue_concurrency,
    :max_response_bytes,
    :max_storage_bytes,
    :operator_allowed_dids,
    :skywatch_did,
    :elder_label
  ]

  @type t :: %__MODULE__{
          bot_enabled: boolean(),
          bot_did: String.t() | nil,
          bot_handle: String.t() | nil,
          bot_pds_url: String.t() | nil,
          appview_url: String.t(),
          poll_interval_ms: pos_integer(),
          notification_page_cap: pos_integer(),
          atproto_http_timeout_ms: pos_integer(),
          atproto_session_timeout_ms: pos_integer(),
          thread_fetch_timeout_ms: pos_integer(),
          anthropic_daily_budget_microdollars: pos_integer() | nil,
          anthropic_model_id: String.t(),
          anthropic_title_model_id: String.t(),
          anthropic_effort: :low | :medium | :high,
          anthropic_http_timeout_ms: pos_integer(),
          anthropic_api_version: String.t(),
          anthropic_web_search_tool_type: String.t(),
          anthropic_web_fetch_tool_type: String.t(),
          anthropic_research_max_tokens: pos_integer(),
          anthropic_length_repair_max_tokens: pos_integer(),
          anthropic_structure_model_id: String.t(),
          anthropic_structure_max_tokens: pos_integer(),
          max_web_search_uses: pos_integer(),
          max_web_fetch_uses: pos_integer(),
          max_web_fetch_content_tokens: pos_integer(),
          max_tool_continuations: pos_integer(),
          anthropic_max_http_retries: pos_integer(),
          anthropic_retry_base_ms: pos_integer(),
          anthropic_retry_max_ms: pos_integer(),
          anthropic_research_reservation_microdollars: pos_integer(),
          anthropic_continuation_reservation_microdollars: pos_integer(),
          anthropic_repair_reservation_microdollars: pos_integer(),
          anthropic_structure_reservation_microdollars: pos_integer(),
          anthropic_retry_reservation_microdollars: pos_integer(),
          anthropic_pricing_version: String.t(),
          thread_parent_height: pos_integer(),
          actor_hourly_limit: pos_integer(),
          actor_daily_limit: pos_integer(),
          actor_daily_limit_public: pos_integer(),
          global_hourly_limit: pos_integer(),
          global_daily_limit: pos_integer(),
          max_pending: pos_integer(),
          queue_concurrency: pos_integer(),
          max_response_bytes: pos_integer(),
          max_storage_bytes: pos_integer(),
          operator_allowed_dids: [String.t()],
          skywatch_did: String.t(),
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
      appview_url: appview_url!(environment),
      poll_interval_ms:
        bounded_integer!(
          environment,
          "POLL_INTERVAL_MS",
          :poll_interval_ms,
          @default_poll_interval_ms,
          @minimum_poll_interval_ms,
          @maximum_poll_interval_ms
        ),
      notification_page_cap:
        bounded_integer!(
          environment,
          "NOTIFICATION_PAGE_CAP",
          :notification_page_cap,
          @default_notification_page_cap,
          1,
          @maximum_notification_page_cap
        ),
      atproto_http_timeout_ms:
        positive_integer!(
          environment,
          "ATPROTO_HTTP_TIMEOUT_MS",
          :atproto_http_timeout_ms,
          @default_atproto_http_timeout_ms
        ),
      atproto_session_timeout_ms:
        positive_integer!(
          environment,
          "ATPROTO_SESSION_TIMEOUT_MS",
          :atproto_session_timeout_ms,
          @default_atproto_session_timeout_ms
        ),
      thread_fetch_timeout_ms:
        positive_integer!(
          environment,
          "THREAD_FETCH_TIMEOUT_MS",
          :thread_fetch_timeout_ms,
          @default_thread_fetch_timeout_ms
        ),
      anthropic_model_id:
        string!(
          environment,
          "ANTHROPIC_MODEL_ID",
          :anthropic_model_id,
          @default_anthropic_model_id
        ),
      anthropic_title_model_id:
        string!(
          environment,
          "ANTHROPIC_TITLE_MODEL_ID",
          :anthropic_title_model_id,
          @default_anthropic_title_model_id
        ),
      anthropic_effort:
        effort!(environment, "ANTHROPIC_EFFORT", :anthropic_effort, @default_anthropic_effort),
      anthropic_http_timeout_ms:
        positive_integer!(
          environment,
          "ANTHROPIC_HTTP_TIMEOUT_MS",
          :anthropic_http_timeout_ms,
          @default_anthropic_http_timeout_ms
        ),
      anthropic_api_version:
        string!(
          environment,
          "ANTHROPIC_API_VERSION",
          :anthropic_api_version,
          @default_anthropic_api_version
        ),
      anthropic_web_search_tool_type:
        string!(
          environment,
          "ANTHROPIC_WEB_SEARCH_TOOL_TYPE",
          :anthropic_web_search_tool_type,
          @default_anthropic_web_search_tool_type
        ),
      anthropic_web_fetch_tool_type:
        string!(
          environment,
          "ANTHROPIC_WEB_FETCH_TOOL_TYPE",
          :anthropic_web_fetch_tool_type,
          @default_anthropic_web_fetch_tool_type
        ),
      anthropic_daily_budget_microdollars:
        optional_microdollars(
          environment,
          "ANTHROPIC_DAILY_BUDGET_USD",
          :anthropic_daily_budget_usd
        ),
      anthropic_research_max_tokens:
        positive_integer!(
          environment,
          "ANTHROPIC_RESEARCH_MAX_TOKENS",
          :anthropic_research_max_tokens,
          @default_anthropic_research_max_tokens
        ),
      anthropic_length_repair_max_tokens:
        positive_integer!(
          environment,
          "ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS",
          :anthropic_length_repair_max_tokens,
          @default_anthropic_length_repair_max_tokens
        ),
      anthropic_structure_model_id:
        string!(
          environment,
          "ANTHROPIC_STRUCTURE_MODEL_ID",
          :anthropic_structure_model_id,
          string!(
            environment,
            "ANTHROPIC_MODEL_ID",
            :anthropic_model_id,
            @default_anthropic_model_id
          )
        ),
      anthropic_structure_max_tokens:
        positive_integer!(
          environment,
          "ANTHROPIC_STRUCTURE_MAX_TOKENS",
          :anthropic_structure_max_tokens,
          @default_anthropic_structure_max_tokens
        ),
      max_web_search_uses:
        positive_integer!(
          environment,
          "MAX_WEB_SEARCH_USES",
          :max_web_search_uses,
          @default_max_web_search_uses
        ),
      max_web_fetch_uses:
        positive_integer!(
          environment,
          "MAX_WEB_FETCH_USES",
          :max_web_fetch_uses,
          @default_max_web_fetch_uses
        ),
      max_web_fetch_content_tokens:
        positive_integer!(
          environment,
          "MAX_WEB_FETCH_CONTENT_TOKENS",
          :max_web_fetch_content_tokens,
          @default_max_web_fetch_content_tokens
        ),
      max_tool_continuations:
        positive_integer!(
          environment,
          "MAX_TOOL_CONTINUATIONS",
          :max_tool_continuations,
          @default_max_tool_continuations
        ),
      anthropic_max_http_retries:
        positive_integer!(
          environment,
          "ANTHROPIC_MAX_HTTP_RETRIES",
          :anthropic_max_http_retries,
          @default_anthropic_max_http_retries
        ),
      anthropic_retry_base_ms:
        positive_integer!(
          environment,
          "ANTHROPIC_RETRY_BASE_MS",
          :anthropic_retry_base_ms,
          @default_anthropic_retry_base_ms
        ),
      anthropic_retry_max_ms:
        positive_integer!(
          environment,
          "ANTHROPIC_RETRY_MAX_MS",
          :anthropic_retry_max_ms,
          @default_anthropic_retry_max_ms
        ),
      anthropic_research_reservation_microdollars:
        microdollars!(
          environment,
          "ANTHROPIC_RESEARCH_RESERVATION_USD",
          :anthropic_research_reservation_usd,
          @default_anthropic_reservation_usd
        ),
      anthropic_continuation_reservation_microdollars:
        microdollars!(
          environment,
          "ANTHROPIC_CONTINUATION_RESERVATION_USD",
          :anthropic_continuation_reservation_usd,
          @default_anthropic_reservation_usd
        ),
      anthropic_repair_reservation_microdollars:
        microdollars!(
          environment,
          "ANTHROPIC_REPAIR_RESERVATION_USD",
          :anthropic_repair_reservation_usd,
          @default_anthropic_reservation_usd
        ),
      anthropic_structure_reservation_microdollars:
        microdollars!(
          environment,
          "ANTHROPIC_STRUCTURE_RESERVATION_USD",
          :anthropic_structure_reservation_usd,
          @default_anthropic_structure_reservation_usd
        ),
      anthropic_retry_reservation_microdollars:
        microdollars!(
          environment,
          "ANTHROPIC_RETRY_RESERVATION_USD",
          :anthropic_retry_reservation_usd,
          @default_anthropic_reservation_usd
        ),
      anthropic_pricing_version:
        string!(
          environment,
          "ANTHROPIC_PRICING_VERSION",
          :anthropic_pricing_version,
          @default_anthropic_pricing_version
        ),
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
      actor_daily_limit_public:
        positive_integer!(
          environment,
          "ACTOR_DAILY_LIMIT_PUBLIC",
          :actor_daily_limit_public,
          @default_actor_daily_limit_public
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
      elder_label: @elder_label
    }

    validate!(settings)
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = settings) do
    validate_appview_url!(settings.appview_url)

    validate_range!(
      settings.poll_interval_ms,
      "POLL_INTERVAL_MS",
      @minimum_poll_interval_ms,
      @maximum_poll_interval_ms
    )

    validate_range!(
      settings.notification_page_cap,
      "NOTIFICATION_PAGE_CAP",
      1,
      @maximum_notification_page_cap
    )

    validate_range!(
      settings.atproto_http_timeout_ms,
      "ATPROTO_HTTP_TIMEOUT_MS",
      1,
      @maximum_atproto_timeout_ms
    )

    validate_range!(
      settings.atproto_session_timeout_ms,
      "ATPROTO_SESSION_TIMEOUT_MS",
      1,
      @maximum_atproto_timeout_ms
    )

    validate_range!(
      settings.thread_fetch_timeout_ms,
      "THREAD_FETCH_TIMEOUT_MS",
      1,
      @maximum_atproto_timeout_ms
    )

    validate_range!(
      settings.anthropic_http_timeout_ms,
      "ANTHROPIC_HTTP_TIMEOUT_MS",
      1,
      @maximum_anthropic_timeout_ms
    )

    validate_effort!(settings.anthropic_effort)

    validate_date!(settings.anthropic_api_version, "ANTHROPIC_API_VERSION")

    validate_tool_type!(
      settings.anthropic_web_search_tool_type,
      "web_search_",
      "ANTHROPIC_WEB_SEARCH_TOOL_TYPE"
    )

    validate_tool_type!(
      settings.anthropic_web_fetch_tool_type,
      "web_fetch_",
      "ANTHROPIC_WEB_FETCH_TOOL_TYPE"
    )

    validate_range!(
      settings.thread_parent_height,
      "THREAD_PARENT_HEIGHT",
      1,
      @maximum_thread_parent_height
    )

    validate_positive!(settings.actor_hourly_limit, "ACTOR_HOURLY_LIMIT")
    validate_positive!(settings.actor_daily_limit, "ACTOR_DAILY_LIMIT")
    validate_positive!(settings.actor_daily_limit_public, "ACTOR_DAILY_LIMIT_PUBLIC")
    validate_positive!(settings.global_hourly_limit, "GLOBAL_HOURLY_LIMIT")
    validate_positive!(settings.global_daily_limit, "GLOBAL_DAILY_LIMIT")
    validate_positive!(settings.max_pending, "MAX_PENDING")
    validate_exact!(settings.queue_concurrency, "QUEUE_CONCURRENCY", 1)

    validate_range!(
      settings.max_response_bytes,
      "ANTHROPIC_RESPONSE_MAX_BYTES",
      1,
      @maximum_response_bytes
    )

    validate_range!(
      settings.max_storage_bytes,
      "PROVIDER_RESPONSE_STORAGE_MAX_BYTES",
      1,
      @maximum_storage_bytes
    )

    validate_range!(
      settings.anthropic_research_max_tokens,
      "ANTHROPIC_RESEARCH_MAX_TOKENS",
      1,
      @maximum_anthropic_research_tokens
    )

    validate_range!(
      settings.anthropic_length_repair_max_tokens,
      "ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS",
      1,
      @maximum_anthropic_repair_tokens
    )

    validate_range!(
      settings.anthropic_structure_max_tokens,
      "ANTHROPIC_STRUCTURE_MAX_TOKENS",
      1,
      @maximum_anthropic_repair_tokens
    )

    validate_range!(
      settings.max_web_search_uses,
      "MAX_WEB_SEARCH_USES",
      1,
      @maximum_web_tool_uses
    )

    validate_range!(settings.max_web_fetch_uses, "MAX_WEB_FETCH_USES", 1, @maximum_web_tool_uses)

    validate_range!(
      settings.max_web_fetch_content_tokens,
      "MAX_WEB_FETCH_CONTENT_TOKENS",
      1,
      @maximum_web_fetch_content_tokens
    )

    validate_range!(
      settings.max_tool_continuations,
      "MAX_TOOL_CONTINUATIONS",
      1,
      @maximum_tool_continuations
    )

    validate_range!(
      settings.anthropic_max_http_retries,
      "ANTHROPIC_MAX_HTTP_RETRIES",
      1,
      @maximum_anthropic_http_retries
    )

    validate_range!(
      settings.anthropic_retry_base_ms,
      "ANTHROPIC_RETRY_BASE_MS",
      1,
      @maximum_anthropic_retry_base_ms
    )

    validate_range!(
      settings.anthropic_retry_max_ms,
      "ANTHROPIC_RETRY_MAX_MS",
      1,
      @maximum_anthropic_retry_max_ms
    )

    if settings.anthropic_retry_max_ms < settings.anthropic_retry_base_ms do
      raise ArgumentError, "ANTHROPIC_RETRY_MAX_MS must be at least ANTHROPIC_RETRY_BASE_MS"
    end

    validate_optional_positive!(
      settings.anthropic_daily_budget_microdollars,
      "ANTHROPIC_DAILY_BUDGET_USD"
    )

    validate_optional_did!(settings.bot_did, "BOT_DID")
    validate_optional_url!(settings.bot_pds_url, "BOT_PDS_URL")

    if settings.max_storage_bytes <= settings.max_response_bytes do
      raise ArgumentError, "MAX_STORAGE_BYTES must be greater than MAX_RESPONSE_BYTES"
    end

    validate_provider_storage_capacity!(settings)

    if settings.bot_enabled do
      require_did!(settings.bot_did, "BOT_DID")
      require_string!(settings.bot_handle, "BOT_HANDLE")
      require_url!(settings.bot_pds_url, "BOT_PDS_URL")

      require_positive!(
        settings.anthropic_daily_budget_microdollars,
        "ANTHROPIC_DAILY_BUDGET_USD"
      )
    end

    validate_anthropic_budget!(settings)

    settings
  end

  @spec bot_enabled?(t()) :: boolean()
  def bot_enabled?(%__MODULE__{bot_enabled: bot_enabled}), do: bot_enabled

  @spec fly_max_kill_timeout_ms() :: pos_integer()
  def fly_max_kill_timeout_ms, do: @fly_max_kill_timeout_ms

  @spec fly_kill_timeout_s() :: pos_integer()
  def fly_kill_timeout_s, do: div(@fly_max_kill_timeout_ms, 1_000)

  @spec shutdown_grace_period_ms(t()) :: pos_integer()
  def shutdown_grace_period_ms(%__MODULE__{anthropic_http_timeout_ms: timeout_ms})
      when is_integer(timeout_ms) and timeout_ms > 0 do
    min(timeout_ms + @drain_grace_buffer_ms, @fly_max_kill_timeout_ms)
  end

  @spec anthropic_reservation_microdollars(
          t(),
          :research | :continuation | :repair | :structure | :retry
        ) :: pos_integer()
  def anthropic_reservation_microdollars(settings, :research),
    do: settings.anthropic_research_reservation_microdollars

  def anthropic_reservation_microdollars(settings, :continuation),
    do: settings.anthropic_continuation_reservation_microdollars

  def anthropic_reservation_microdollars(settings, :repair),
    do: settings.anthropic_repair_reservation_microdollars

  def anthropic_reservation_microdollars(settings, :structure),
    do: settings.anthropic_structure_reservation_microdollars

  def anthropic_reservation_microdollars(settings, :retry),
    do: settings.anthropic_retry_reservation_microdollars

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

  defp bounded_integer!(environment, environment_key, option_key, default, minimum, maximum) do
    value = positive_integer!(environment, environment_key, option_key, default)
    validate_range!(value, environment_key, minimum, maximum)
  end

  defp optional_microdollars(environment, environment_key, option_key) do
    case fetch(environment, environment_key, option_key, nil) do
      nil -> nil
      value -> parse_microdollars!(value, environment_key)
    end
  end

  defp microdollars!(environment, environment_key, option_key, default) do
    environment
    |> fetch(environment_key, option_key, default)
    |> parse_microdollars!(environment_key)
  end

  defp string!(environment, environment_key, option_key, default) do
    case fetch(environment, environment_key, option_key, default) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{environment_key} must be a nonempty string"
    end
  end

  defp effort!(environment, environment_key, option_key, default) do
    case fetch(environment, environment_key, option_key, default) do
      value when value in [:low, :medium, :high] -> value
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      _invalid -> raise ArgumentError, "ANTHROPIC_EFFORT must be low, medium, or high"
    end
  end

  defp validate_effort!(value) when value in [:low, :medium, :high], do: value

  defp validate_effort!(_value),
    do: raise(ArgumentError, "ANTHROPIC_EFFORT must be low, medium, or high")

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

  defp url!(environment, environment_key, option_key, default) do
    environment
    |> string!(environment_key, option_key, default)
    |> parse_url!(environment_key)
  end

  defp appview_url!(environment) do
    environment
    |> url!("APPVIEW_URL", :appview_url, @default_appview_url)
    |> validate_appview_url!()
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

  defp parse_microdollars!(value, environment_key) do
    case Money.parse_usd(value) do
      {:ok, microdollars} when microdollars > 0 ->
        microdollars

      _invalid ->
        raise ArgumentError,
              "#{environment_key} must be a positive decimal USD amount with at most six fractional places"
    end
  end

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

  defp validate_appview_url!(@default_appview_url), do: @default_appview_url

  defp validate_appview_url!(_value) do
    raise ArgumentError, "APPVIEW_URL must be the reviewed #{@default_appview_url} origin"
  end

  defp validate_date!(value, environment_key) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} ->
        value

      {:error, _reason} ->
        raise ArgumentError, "#{environment_key} must be an ISO date (YYYY-MM-DD)"
    end
  end

  defp validate_date!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} must be an ISO date (YYYY-MM-DD)")

  defp validate_tool_type!(value, prefix, environment_key) when is_binary(value) do
    date = String.replace_prefix(value, prefix, "")

    with true <- String.starts_with?(value, prefix),
         8 <- byte_size(date),
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2)>> <- date,
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {:ok, _date} <- Date.new(year, month, day) do
      value
    else
      _ ->
        raise ArgumentError,
              "#{environment_key} must be #{prefix} followed by a valid YYYYMMDD date"
    end
  end

  defp validate_tool_type!(_value, prefix, environment_key),
    do:
      raise(
        ArgumentError,
        "#{environment_key} must be #{prefix} followed by a valid YYYYMMDD date"
      )

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

  defp require_positive!(value, _environment_key) when is_integer(value) and value > 0, do: value

  defp require_positive!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} is required when BOT_ENABLED=true")

  defp validate_positive!(value, _environment_key) when is_integer(value) and value > 0, do: value

  defp validate_positive!(_value, environment_key),
    do: raise(ArgumentError, "#{environment_key} must be a positive integer")

  defp validate_range!(value, _environment_key, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: value

  defp validate_range!(_value, environment_key, minimum, maximum) do
    raise ArgumentError, "#{environment_key} must be between #{minimum} and #{maximum}"
  end

  defp validate_exact!(value, _environment_key, expected) when value == expected, do: value

  defp validate_exact!(_value, environment_key, expected) do
    raise ArgumentError, "#{environment_key} must be exactly #{expected}"
  end

  defp validate_optional_positive!(nil, _environment_key), do: :ok

  defp validate_optional_positive!(value, environment_key),
    do: validate_positive!(value, environment_key)

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

  defp validate_anthropic_budget!(settings) do
    pricing = pricing!(settings.anthropic_pricing_version)

    research_maximum =
      maximum_exposure!(settings.anthropic_research_max_tokens, settings, pricing)

    repair_maximum =
      maximum_exposure!(settings.anthropic_length_repair_max_tokens, settings, pricing)

    structure_maximum = structure_exposure!(settings, pricing)

    reservations = [
      {"ANTHROPIC_RESEARCH_RESERVATION_USD", settings.anthropic_research_reservation_microdollars,
       research_maximum},
      {"ANTHROPIC_CONTINUATION_RESERVATION_USD",
       settings.anthropic_continuation_reservation_microdollars, research_maximum},
      {"ANTHROPIC_REPAIR_RESERVATION_USD", settings.anthropic_repair_reservation_microdollars,
       repair_maximum},
      {"ANTHROPIC_STRUCTURE_RESERVATION_USD",
       settings.anthropic_structure_reservation_microdollars, structure_maximum},
      {"ANTHROPIC_RETRY_RESERVATION_USD", settings.anthropic_retry_reservation_microdollars,
       max(research_maximum, max(repair_maximum, structure_maximum))}
    ]

    Enum.each(reservations, fn {name, reservation, maximum} ->
      if reservation < maximum do
        raise ArgumentError,
              "#{name} must cover the configured maximum exposure of #{maximum} microdollars"
      end

      if settings.anthropic_daily_budget_microdollars &&
           reservation > settings.anthropic_daily_budget_microdollars do
        raise ArgumentError, "#{name} must not exceed the Anthropic daily budget"
      end
    end)
  end

  defp validate_provider_storage_capacity!(settings) do
    maximum_recorded_responses =
      1 + settings.max_tool_continuations + 1 + 1 + settings.anthropic_max_http_retries

    required_bytes =
      maximum_recorded_responses *
        (settings.max_response_bytes + ResponseEnvelope.max_overhead_bytes())

    if settings.max_storage_bytes < required_bytes do
      raise ArgumentError,
            "PROVIDER_RESPONSE_STORAGE_MAX_BYTES must retain all permitted responses and envelope metadata (at least #{required_bytes})"
    end
  end

  defp pricing!(version) do
    case Pricing.fetch(version) do
      {:ok, pricing} ->
        pricing

      {:error, :unknown_pricing_version} ->
        raise ArgumentError, "ANTHROPIC_PRICING_VERSION is not supported: #{inspect(version)}"
    end
  end

  defp structure_exposure!(settings, pricing) do
    usage = %{
      input_tokens: 0,
      cache_creation_input_tokens: settings.anthropic_research_max_tokens,
      cache_creation: %{
        ephemeral_5m_input_tokens: 0,
        ephemeral_1h_input_tokens: settings.anthropic_research_max_tokens
      },
      cache_read_input_tokens: 0,
      output_tokens: settings.anthropic_structure_max_tokens,
      server_tool_use: %{web_search_requests: 0}
    }

    {:ok, maximum} = Pricing.maximum_cost(usage, pricing)
    maximum
  end

  defp maximum_exposure!(output_tokens, settings, pricing) do
    usage = %{
      input_tokens: 0,
      cache_creation_input_tokens: pricing.max_context_tokens,
      cache_creation: %{
        ephemeral_5m_input_tokens: 0,
        ephemeral_1h_input_tokens: pricing.max_context_tokens
      },
      cache_read_input_tokens: 0,
      output_tokens: output_tokens,
      server_tool_use: %{web_search_requests: settings.max_web_search_uses}
    }

    {:ok, maximum} = Pricing.maximum_cost(usage, pricing)
    maximum
  end

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

  defp fetch_first(_environment, [], default), do: default

  defp fetch_first(environment, [{environment_key, option_key} | remaining_keys], default) do
    case fetch(environment, environment_key, option_key, :missing) do
      :missing -> fetch_first(environment, remaining_keys, default)
      value -> value
    end
  end
end
