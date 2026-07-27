defmodule ContextBot.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ContextBotWeb.Telemetry,
      ContextBot.Repo,
      {DNSCluster, query: Application.get_env(:context_bot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ContextBot.PubSub},
      # Start a worker by calling: ContextBot.Worker.start_link(arg)
      # {ContextBot.Worker, arg},
      # Start to serve requests, typically the last entry
      ContextBotWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ContextBot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ContextBotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
