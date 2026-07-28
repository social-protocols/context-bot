defmodule ContextBotWeb.ProductionConfigTest do
  use ExUnit.Case, async: true

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
end
