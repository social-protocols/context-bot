# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :context_bot,
  ecto_repos: [ContextBot.Repo],
  generators: [timestamp_type: :utc_datetime]

config :context_bot, ContextBot.Repo, log: false

config :context_bot, Oban,
  engine: Oban.Engines.Lite,
  repo: ContextBot.Repo,
  queues: [eligibility: 1, thread: 1, research: 1, reply: 1, maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"* * * * *", ContextBot.Workers.DeferredWorker}]}
  ]

# Configure the endpoint
config :context_bot, ContextBotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ContextBotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ContextBot.PubSub,
  live_view: [signing_salt: "WXfARleR"]

# Configure all application and OTP output as one safe JSON object per line.
config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {ContextBot.Logging.JSONFormatter, %{}}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
