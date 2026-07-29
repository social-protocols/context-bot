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
      Settings.load(bot_enabled: "true", anthropic_daily_budget_usd: "1.00")
    end
  end

  test "production runtime requires the bot app password when enabled" do
    replace_environment(%{
      "BOT_ENABLED" => "true",
      "BOT_DID" => "did:plc:botidentifier",
      "BOT_HANDLE" => "contextbot.bsky.social",
      "BOT_PDS_URL" => "https://bsky.social",
      "ANTHROPIC_DAILY_BUDGET_USD" => "1.00",
      "BOT_APP_PASSWORD" => nil,
      "ANTHROPIC_API_KEY" => nil
    })

    assert_raise RuntimeError, ~r/BOT_APP_PASSWORD/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "runtime config applies queue concurrency to every manual queue" do
    replace_environment(%{"BOT_ENABLED" => "false", "QUEUE_CONCURRENCY" => "3"})

    queues =
      "config/runtime.exs"
      |> Config.Reader.read!(env: :test)
      |> Keyword.fetch!(:context_bot)
      |> Keyword.fetch!(Oban)
      |> Keyword.fetch!(:queues)

    assert queues == [eligibility: 3, thread: 3, research: 3, reply: 3, maintenance: 3]
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
end
