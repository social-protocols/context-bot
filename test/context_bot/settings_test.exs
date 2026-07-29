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
end
