defmodule ContextBotWeb.Router do
  use ContextBotWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ContextBotWeb do
    pipe_through :api
  end
end
