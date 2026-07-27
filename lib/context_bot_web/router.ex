defmodule ContextBotWeb.Router do
  use ContextBotWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ContextBotWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
