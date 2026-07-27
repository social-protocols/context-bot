defmodule ContextBotWeb.HealthControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET /health reports that the service is running", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
