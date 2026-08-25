defmodule ContextBotWeb.Router do
  use ContextBotWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ContextBotWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", ContextBotWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
