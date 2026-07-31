defmodule ContextBot.SettingsTest do
  use ExUnit.Case, async: true

  alias ContextBot.Settings

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
        anthropic_response_max_bytes: "64",
        provider_response_storage_max_bytes: "65"
      )

    assert settings.max_response_bytes == 64
    assert settings.max_storage_bytes == 65
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

  test "uses the canonical public web-search cap in maximum-exposure validation" do
    assert_raise ArgumentError, ~r/ANTHROPIC_RESEARCH_RESERVATION_USD.*maximum exposure/, fn ->
      Settings.load(max_web_search_uses: 101)
    end
  end
end
