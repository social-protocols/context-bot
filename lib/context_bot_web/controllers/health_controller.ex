defmodule ContextBotWeb.HealthController do
  use ContextBotWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
