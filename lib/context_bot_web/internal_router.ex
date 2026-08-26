defmodule ContextBotWeb.InternalRouter do
  @moduledoc """
  Router for internal operator endpoints.
  """

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  scope "/", ContextBotWeb do
    pipe_through :browser

    get "/invocations", InternalController, :index
  end
end
