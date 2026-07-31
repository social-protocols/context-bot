defmodule ContextBotWeb.HealthControllerTest do
  use ContextBotWeb.ConnCase, async: false

  alias ContextBot.Operations
  alias ContextBot.Settings

  setup do
    previous = Application.get_env(:context_bot, Operations)

    on_exit(fn ->
      if previous do
        Application.put_env(:context_bot, Operations, previous)
      else
        Application.delete_env(:context_bot, Operations)
      end
    end)

    :ok
  end

  test "GET /health reports that the service is running", %{conn: conn} do
    Application.put_env(:context_bot, Operations,
      now: ~U[2026-07-31 12:00:00Z],
      settings: Settings.load(bot_enabled: false)
    )

    conn = get(conn, ~p"/health")

    assert %{
             "status" => "ok",
             "bot" => %{"enabled" => false, "session" => "disabled"}
           } = json_response(conn, 200)
  end

  test "GET /health remains liveness-successful when provider session state is degraded", %{
    conn: conn
  } do
    Application.put_env(:context_bot, Operations,
      now: ~U[2026-07-31 12:00:00Z],
      settings:
        Settings.load(
          bot_enabled: true,
          bot_did: "did:plc:botbotbotbotbotbotbotbot",
          bot_handle: "contextbot.example",
          bot_pds_url: "https://pds.private.example",
          anthropic_daily_budget_usd: "10.000000"
        ),
      session_status: fn -> raise "secret provider failure" end
    )

    body = conn |> get(~p"/health") |> json_response(200)

    assert body["status"] == "ok"
    assert body["bot"] == %{"enabled" => true, "session" => "unavailable"}
    refute Jason.encode!(body) =~ "secret provider failure"
  end
end
