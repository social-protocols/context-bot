defmodule ContextBotWeb.HealthController do
  use ContextBotWeb, :controller

  alias ContextBot.Operations

  def show(conn, _params) do
    json(conn, Operations.health())
  end
end
