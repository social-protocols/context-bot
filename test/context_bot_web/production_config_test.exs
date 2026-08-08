defmodule ContextBotWeb.ProductionConfigTest do
  use ExUnit.Case, async: false

  alias ContextBot.Settings

  test "production health checks are not redirected to HTTPS" do
    config = Config.Reader.read!("config/prod.exs")

    excluded_paths =
      config
      |> Keyword.fetch!(:context_bot)
      |> Keyword.fetch!(ContextBotWeb.Endpoint)
      |> Keyword.fetch!(:force_ssl)
      |> Keyword.fetch!(:exclude)
      |> Keyword.fetch!(:paths)

    assert "/health" in excluded_paths
  end

  test "enabled bots require their non-secret production identity settings" do
    assert_raise ArgumentError, ~r/BOT_DID/, fn ->
      Settings.load(bot_enabled: "true", anthropic_daily_budget_usd: "10.00")
    end
  end

  test "production runtime requires the bot app password when enabled" do
    replace_environment(%{
      "BOT_ENABLED" => "true",
      "BOT_DID" => "did:plc:botidentifier",
      "BOT_HANDLE" => "contextbot.bsky.social",
      "BOT_PDS_URL" => "https://bsky.social",
      "ANTHROPIC_DAILY_BUDGET_USD" => "10.00",
      "BOT_APP_PASSWORD" => nil,
      "ANTHROPIC_API_KEY" => nil
    })

    assert_raise RuntimeError, ~r/BOT_APP_PASSWORD/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production runtime rejects a blank bot app password when enabled" do
    replace_environment(
      enabled_bot_environment(%{"BOT_APP_PASSWORD" => "", "ANTHROPIC_API_KEY" => "test-key"})
    )

    assert_raise RuntimeError, ~r/BOT_APP_PASSWORD/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production runtime requires an Anthropic API key when enabled" do
    replace_environment(
      enabled_bot_environment(%{
        "BOT_APP_PASSWORD" => "test-password",
        "ANTHROPIC_API_KEY" => nil
      })
    )

    assert_raise RuntimeError, ~r/ANTHROPIC_API_KEY/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "production runtime rejects a blank Anthropic API key when enabled" do
    replace_environment(
      enabled_bot_environment(%{"BOT_APP_PASSWORD" => "test-password", "ANTHROPIC_API_KEY" => ""})
    )

    assert_raise RuntimeError, ~r/ANTHROPIC_API_KEY/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "runtime config keeps every workflow queue serial" do
    replace_environment(%{"BOT_ENABLED" => "false", "QUEUE_CONCURRENCY" => "1"})

    queues =
      "config/runtime.exs"
      |> Config.Reader.read!(env: :test)
      |> Keyword.fetch!(:context_bot)
      |> Keyword.fetch!(Oban)
      |> Keyword.fetch!(:queues)

    assert queues == [eligibility: 1, thread: 1, research: 1, reply: 1, maintenance: 1]
  end

  defp replace_environment(changes) do
    original = Map.new(changes, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(changes, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  defp enabled_bot_environment(overrides) do
    Map.merge(
      %{
        "BOT_ENABLED" => "true",
        "BOT_DID" => "did:plc:botidentifier",
        "BOT_HANDLE" => "contextbot.bsky.social",
        "BOT_PDS_URL" => "https://bsky.social",
        "ANTHROPIC_DAILY_BUDGET_USD" => "10.00"
      },
      overrides
    )
  end
end
