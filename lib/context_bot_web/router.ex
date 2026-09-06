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
    get "/invocations", InvocationsController, :index
    get "/r/:id", FullResponseController, :show
  end

  scope "/", ContextBotWeb do
    pipe_through :api

    get "/health", HealthController, :show

    # Product SQLite tables only. Oban/Phoenix internals stay unpublished.
    # Plug forbids ":id.json" as a param name, so show routes accept
    # "/:id" and "/:id.json" (PublicData.parse_id/1 strips the suffix).
    get "/invocations.json", InvocationsController, :index_json
    get "/invocations/:id", InvocationsController, :show
    get "/api_budget_entries.json", BudgetEntriesController, :index
    get "/api_budget_entries/:id", BudgetEntriesController, :show
    get "/anthropic_response_envelopes.json", ResponseEnvelopesController, :index
    get "/anthropic_response_envelopes/:id", ResponseEnvelopesController, :show
  end
end
