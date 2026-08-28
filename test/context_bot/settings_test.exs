defmodule ContextBot.SettingsTest do
  use ExUnit.Case, async: true

  alias ContextBot.Settings

  test "caps Oban drain grace at Fly's kill_timeout maximum" do
    assert Settings.fly_max_kill_timeout_ms() == 300_000
    assert Settings.fly_kill_timeout_s() == 300

    default = Settings.load([])
    assert Settings.shutdown_grace_period_ms(default) == 300_000

    short = Settings.load(anthropic_http_timeout_ms: 60_000)
    assert Settings.shutdown_grace_period_ms(short) == 75_000
  end

  test "loads the documented operational defaults" do
    settings = Settings.load([])

    assert settings.bot_enabled == false
    assert settings.thread_parent_height == 80
    assert settings.actor_hourly_limit == 2
    assert settings.actor_daily_limit == 5
    assert settings.global_hourly_limit == 10
    assert settings.global_daily_limit == 50
    assert settings.max_pending == 25
    assert settings.queue_concurrency == 1
    assert settings.max_response_bytes == 8_000_000
    assert settings.max_storage_bytes == 64_000_000
    assert settings.anthropic_daily_budget_microdollars == nil
    assert is_integer(settings.anthropic_research_reservation_microdollars)
    assert is_integer(settings.anthropic_continuation_reservation_microdollars)
    assert is_integer(settings.anthropic_repair_reservation_microdollars)
    assert is_integer(settings.anthropic_retry_reservation_microdollars)
    assert settings.anthropic_pricing_version == "sonnet-5-2026-07-28"
    assert settings.anthropic_model_id == "claude-sonnet-5"
    assert settings.anthropic_effort == :medium
    assert settings.anthropic_research_max_tokens == 4_096
    assert settings.max_web_search_uses == 5
    assert settings.anthropic_research_reservation_microdollars == 5_000_000
    assert settings.max_web_fetch_uses == 2
    assert settings.max_web_fetch_content_tokens == 10_000
    assert settings.max_tool_continuations == 1
    assert settings.anthropic_max_http_retries == 2
    assert settings.anthropic_retry_base_ms == 1_000
    assert settings.anthropic_retry_max_ms == 30_000
    assert settings.appview_url == "https://api.bsky.app"
    assert settings.poll_interval_ms == 30_000
    assert settings.notification_page_cap == 5
    assert settings.atproto_http_timeout_ms == 15_000
    assert settings.atproto_session_timeout_ms == 15_000
    assert settings.thread_fetch_timeout_ms == 20_000
    assert settings.anthropic_http_timeout_ms == 300_000
    assert settings.anthropic_api_version == "2023-06-01"
    assert settings.anthropic_web_search_tool_type == "web_search_20260318"
    assert settings.anthropic_web_fetch_tool_type == "web_fetch_20260318"
  end

  test "loads and validates Anthropic effort" do
    assert Settings.load(%{"ANTHROPIC_EFFORT" => "low"}).anthropic_effort == :low
    assert Settings.load(anthropic_effort: "medium").anthropic_effort == :medium
    assert Settings.load(anthropic_effort: :high).anthropic_effort == :high

    for invalid <- ["", "minimal", "HIGH", :minimal, 1] do
      assert_raise ArgumentError, ~r/ANTHROPIC_EFFORT/, fn ->
        Settings.load(anthropic_effort: invalid)
      end
    end
  end

  test "rejects malformed non-secret settings" do
    assert_raise ArgumentError, ~r/THREAD_PARENT_HEIGHT/, fn ->
      Settings.load(thread_parent_height: "80.5")
    end

    assert_raise ArgumentError, ~r/THREAD_PARENT_HEIGHT/, fn ->
      Settings.load(thread_parent_height: false)
    end

    assert_raise ArgumentError, ~r/BOT_ENABLED/, fn ->
      Settings.load(bot_enabled: "yes")
    end

    assert_raise ArgumentError, ~r/OPERATOR_ALLOWED_DIDS/, fn ->
      Settings.load(operator_allowed_dids: "did:plc:valid, not-a-did")
    end

    assert_raise ArgumentError, ~r/ANTHROPIC_DAILY_BUDGET_USD/, fn ->
      Settings.load(anthropic_daily_budget_usd: "0")
    end

    assert_raise ArgumentError, ~r/ANTHROPIC_DAILY_BUDGET_USD/, fn ->
      Settings.load(anthropic_daily_budget_usd: "1.0000001")
    end

    assert_raise ArgumentError, ~r/MAX_STORAGE_BYTES/, fn ->
      Settings.load(max_response_bytes: "64", max_storage_bytes: "64")
    end
  end

  test "requires an exact DID for an enabled bot" do
    assert_raise ArgumentError, ~r/BOT_DID/, fn ->
      Settings.load(
        bot_enabled: "true",
        bot_did: "not-a-did",
        bot_handle: "contextbot.bsky.social",
        bot_pds_url: "https://bsky.social",
        anthropic_daily_budget_usd: "1.00"
      )
    end
  end

  test "loads documented response and storage limit names" do
    settings =
      Settings.load(
        anthropic_response_max_bytes: "7000000",
        provider_response_storage_max_bytes: "64000000"
      )

    assert settings.max_response_bytes == 7_000_000
    assert settings.max_storage_bytes == 64_000_000
  end

  test "rejects operational controls outside reviewed upper bounds" do
    for {environment, expected_name} <- [
          {%{"ATPROTO_HTTP_TIMEOUT_MS" => "60001"}, "ATPROTO_HTTP_TIMEOUT_MS"},
          {%{"ATPROTO_SESSION_TIMEOUT_MS" => "60001"}, "ATPROTO_SESSION_TIMEOUT_MS"},
          {%{"THREAD_FETCH_TIMEOUT_MS" => "60001"}, "THREAD_FETCH_TIMEOUT_MS"},
          {%{"ANTHROPIC_HTTP_TIMEOUT_MS" => "600001"}, "ANTHROPIC_HTTP_TIMEOUT_MS"},
          {%{"THREAD_PARENT_HEIGHT" => "101"}, "THREAD_PARENT_HEIGHT"},
          {%{"ANTHROPIC_RESEARCH_MAX_TOKENS" => "64001"}, "ANTHROPIC_RESEARCH_MAX_TOKENS"},
          {%{"ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS" => "8193"},
           "ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS"},
          {%{"MAX_WEB_SEARCH_USES" => "11"}, "MAX_WEB_SEARCH_USES"},
          {%{"MAX_WEB_FETCH_USES" => "11"}, "MAX_WEB_FETCH_USES"},
          {%{"MAX_WEB_FETCH_CONTENT_TOKENS" => "100001"}, "MAX_WEB_FETCH_CONTENT_TOKENS"},
          {%{"MAX_TOOL_CONTINUATIONS" => "6"}, "MAX_TOOL_CONTINUATIONS"},
          {%{"ANTHROPIC_MAX_HTTP_RETRIES" => "4"}, "ANTHROPIC_MAX_HTTP_RETRIES"},
          {%{"ANTHROPIC_RETRY_BASE_MS" => "60001"}, "ANTHROPIC_RETRY_BASE_MS"},
          {%{"ANTHROPIC_RETRY_MAX_MS" => "300001"}, "ANTHROPIC_RETRY_MAX_MS"},
          {%{"ANTHROPIC_RESPONSE_MAX_BYTES" => "16000001"}, "ANTHROPIC_RESPONSE_MAX_BYTES"},
          {%{"PROVIDER_RESPONSE_STORAGE_MAX_BYTES" => "128000001"},
           "PROVIDER_RESPONSE_STORAGE_MAX_BYTES"},
          {%{"QUEUE_CONCURRENCY" => "2"}, "QUEUE_CONCURRENCY"}
        ] do
      assert_raise ArgumentError, ~r/#{expected_name}/, fn -> Settings.load(environment) end
    end
  end

  test "storage cap covers every permitted response plus envelope headroom" do
    assert_raise ArgumentError, ~r/PROVIDER_RESPONSE_STORAGE_MAX_BYTES.*all permitted/, fn ->
      Settings.load(
        anthropic_response_max_bytes: "8000000",
        provider_response_storage_max_bytes: "32000001"
      )
    end
  end

  test "parses daily and per-request USD settings into integer microdollars" do
    settings =
      Settings.load(
        anthropic_daily_budget_usd: "20.234567",
        anthropic_research_reservation_usd: "5.150001",
        anthropic_continuation_reservation_usd: "5.150002",
        anthropic_repair_reservation_usd: "5.150003",
        anthropic_retry_reservation_usd: "5.150004"
      )

    assert settings.anthropic_daily_budget_microdollars == 20_234_567
    assert settings.anthropic_research_reservation_microdollars == 5_150_001
    assert settings.anthropic_continuation_reservation_microdollars == 5_150_002
    assert settings.anthropic_repair_reservation_microdollars == 5_150_003
    assert settings.anthropic_retry_reservation_microdollars == 5_150_004
    refute Map.has_key?(settings, :anthropic_daily_budget_usd)
  end

  test "rejects reservations above the daily limit" do
    assert_raise ArgumentError, ~r/ANTHROPIC_RESEARCH_RESERVATION_USD.*daily budget/, fn ->
      Settings.load(
        anthropic_daily_budget_usd: "4.999999",
        anthropic_research_reservation_usd: "5.000000"
      )
    end
  end

  test "rejects reservations below configured maximum request exposure" do
    assert_raise ArgumentError, ~r/ANTHROPIC_RESEARCH_RESERVATION_USD.*maximum exposure/, fn ->
      Settings.load(
        anthropic_daily_budget_usd: "10.00",
        anthropic_research_max_tokens: 100,
        anthropic_length_repair_max_tokens: 50,
        max_web_search_uses: 2,
        anthropic_research_reservation_usd: "4.020999",
        anthropic_continuation_reservation_usd: "5.000000",
        anthropic_repair_reservation_usd: "5.000000",
        anthropic_retry_reservation_usd: "5.000000"
      )
    end
  end

  test "rejects a retry reservation that cannot cover the largest request class" do
    assert_raise ArgumentError, ~r/ANTHROPIC_RETRY_RESERVATION_USD.*maximum exposure/, fn ->
      Settings.load(
        anthropic_daily_budget_usd: "10.00",
        anthropic_research_max_tokens: 100,
        anthropic_length_repair_max_tokens: 50,
        max_web_search_uses: 2,
        anthropic_research_reservation_usd: "5.000000",
        anthropic_continuation_reservation_usd: "5.000000",
        anthropic_repair_reservation_usd: "5.000000",
        anthropic_retry_reservation_usd: "4.020999"
      )
    end
  end

  test "rejects an unknown pricing table before startup" do
    assert_raise ArgumentError, ~r/ANTHROPIC_PRICING_VERSION/, fn ->
      Settings.load(anthropic_pricing_version: "future-prices")
    end
  end

  test "loads the canonical public web-search cap from environment and options" do
    assert Settings.load(%{"MAX_WEB_SEARCH_USES" => "3"}).max_web_search_uses == 3
    assert Settings.load(max_web_search_uses: 4).max_web_search_uses == 4
  end

  test "loads and validates the approved research-runner bounds" do
    settings =
      Settings.load(
        anthropic_model_id: "claude-sonnet-5-20260715",
        max_web_fetch_uses: 2,
        max_web_fetch_content_tokens: 12_000,
        max_tool_continuations: 4,
        anthropic_max_http_retries: 3,
        anthropic_retry_base_ms: 250,
        anthropic_retry_max_ms: 5_000,
        provider_response_storage_max_bytes: 80_000_000
      )

    assert settings.anthropic_model_id == "claude-sonnet-5-20260715"
    assert settings.max_web_fetch_uses == 2
    assert settings.max_web_fetch_content_tokens == 12_000
    assert settings.max_tool_continuations == 4
    assert settings.anthropic_max_http_retries == 3
    assert settings.anthropic_retry_base_ms == 250
    assert settings.anthropic_retry_max_ms == 5_000

    assert_raise ArgumentError, ~r/ANTHROPIC_RETRY_MAX_MS/, fn ->
      Settings.load(anthropic_retry_base_ms: 5_001, anthropic_retry_max_ms: 5_000)
    end
  end

  test "uses the canonical public web-search cap in maximum-exposure validation" do
    assert_raise ArgumentError, ~r/ANTHROPIC_RESEARCH_RESERVATION_USD.*maximum exposure/, fn ->
      Settings.load(
        max_web_search_uses: 10,
        anthropic_research_reservation_usd: "0.000001"
      )
    end
  end

  test "loads every external request control from the environment" do
    settings =
      Settings.load(%{
        "APPVIEW_URL" => "https://api.bsky.app",
        "POLL_INTERVAL_MS" => "5000",
        "NOTIFICATION_PAGE_CAP" => "20",
        "ATPROTO_HTTP_TIMEOUT_MS" => "2345",
        "ATPROTO_SESSION_TIMEOUT_MS" => "3456",
        "THREAD_FETCH_TIMEOUT_MS" => "4567",
        "ANTHROPIC_HTTP_TIMEOUT_MS" => "5678",
        "ANTHROPIC_API_VERSION" => "2027-08-09",
        "ANTHROPIC_WEB_SEARCH_TOOL_TYPE" => "web_search_20270809",
        "ANTHROPIC_WEB_FETCH_TOOL_TYPE" => "web_fetch_20270809"
      })

    assert settings.appview_url == "https://api.bsky.app"
    assert settings.poll_interval_ms == 5_000
    assert settings.notification_page_cap == 20
    assert settings.atproto_http_timeout_ms == 2_345
    assert settings.atproto_session_timeout_ms == 3_456
    assert settings.thread_fetch_timeout_ms == 4_567
    assert settings.anthropic_http_timeout_ms == 5_678
    assert settings.anthropic_api_version == "2027-08-09"
    assert settings.anthropic_web_search_tool_type == "web_search_20270809"
    assert settings.anthropic_web_fetch_tool_type == "web_fetch_20270809"
  end

  test "keeps the AppView trust root and polling controls within reviewed bounds" do
    assert Settings.load(%{"POLL_INTERVAL_MS" => "5000"}).poll_interval_ms == 5_000
    assert Settings.load(%{"POLL_INTERVAL_MS" => "3600000"}).poll_interval_ms == 3_600_000
    assert Settings.load(%{"NOTIFICATION_PAGE_CAP" => "1"}).notification_page_cap == 1
    assert Settings.load(%{"NOTIFICATION_PAGE_CAP" => "20"}).notification_page_cap == 20

    for environment <- [
          %{"APPVIEW_URL" => "https://appview.example.test"},
          %{"APPVIEW_URL" => "https://api.bsky.app/"},
          %{"POLL_INTERVAL_MS" => "4999"},
          %{"POLL_INTERVAL_MS" => "3600001"},
          %{"NOTIFICATION_PAGE_CAP" => "0"},
          %{"NOTIFICATION_PAGE_CAP" => "21"}
        ] do
      assert_raise ArgumentError, fn -> Settings.load(environment) end
    end
  end

  test "rejects malformed external request controls" do
    for {environment, expected_name} <- [
          {%{"APPVIEW_URL" => "http://api.bsky.app"}, "APPVIEW_URL"},
          {%{"POLL_INTERVAL_MS" => "0"}, "POLL_INTERVAL_MS"},
          {%{"NOTIFICATION_PAGE_CAP" => "unbounded"}, "NOTIFICATION_PAGE_CAP"},
          {%{"ATPROTO_HTTP_TIMEOUT_MS" => "-1"}, "ATPROTO_HTTP_TIMEOUT_MS"},
          {%{"ATPROTO_SESSION_TIMEOUT_MS" => "0"}, "ATPROTO_SESSION_TIMEOUT_MS"},
          {%{"THREAD_FETCH_TIMEOUT_MS" => "forever"}, "THREAD_FETCH_TIMEOUT_MS"},
          {%{"ANTHROPIC_HTTP_TIMEOUT_MS" => "0"}, "ANTHROPIC_HTTP_TIMEOUT_MS"},
          {%{"ANTHROPIC_API_VERSION" => "latest"}, "ANTHROPIC_API_VERSION"},
          {%{"ANTHROPIC_WEB_SEARCH_TOOL_TYPE" => "web_fetch_20260318"},
           "ANTHROPIC_WEB_SEARCH_TOOL_TYPE"},
          {%{"ANTHROPIC_WEB_FETCH_TOOL_TYPE" => "web_fetch_latest"},
           "ANTHROPIC_WEB_FETCH_TOOL_TYPE"}
        ] do
      assert_raise ArgumentError, ~r/#{expected_name}/, fn -> Settings.load(environment) end
    end
  end
end
