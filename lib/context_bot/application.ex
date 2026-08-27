defmodule ContextBot.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias ContextBot.Runtime.Drain

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
      ] ++ bot_children(settings) ++ [ContextBotWeb.Endpoint, ContextBotWeb.InternalEndpoint]

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
    ContextBotWeb.InternalEndpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def prep_stop(state) do
    _ = Drain.begin()
    state
  end

  @doc false
  def bot_children(settings) do
    if ContextBot.Settings.bot_enabled?(settings) do
      [
        {ContextBot.Workflow.StartupRecovery, []},
        {Oban, Application.fetch_env!(:context_bot, Oban)},
        {ContextBot.ATProto.Session, timeout: settings.atproto_session_timeout_ms},
        {ContextBot.Mentions.Poller,
         name: ContextBot.Mentions.Poller,
         poll_interval_ms: settings.poll_interval_ms,
         page_cap: settings.notification_page_cap}
      ]
    else
      []
    end
  end
end
