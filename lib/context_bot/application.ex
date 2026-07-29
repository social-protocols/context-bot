defmodule ContextBot.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    settings = Application.fetch_env!(:context_bot, :settings)

    children =
      [
        ContextBotWeb.Telemetry,
        ContextBot.Repo,
        {Finch, name: ContextBot.Finch},
        {DNSCluster, query: Application.get_env(:context_bot, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ContextBot.PubSub}
      ] ++ bot_children(settings) ++ [ContextBotWeb.Endpoint]

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

  defp bot_children(settings) do
    if ContextBot.Settings.bot_enabled?(settings) do
      [{Oban, Application.fetch_env!(:context_bot, Oban)}]
    else
      []
    end
  end
end
