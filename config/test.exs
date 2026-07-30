import Config

partition = System.get_env("MIX_TEST_PARTITION")
database_name = "context_bot_test#{partition}.db"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :context_bot, ContextBot.Repo,
  database: Path.expand("../data/#{database_name}", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  journal_mode: :wal,
  busy_timeout: 5_000

config :context_bot, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :context_bot, ContextBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bOhu4TwCOlOVSuWqL/yiRk1pE1zTuULQ0LCQJv+nwjqBqtMvjZGWkVPRhoovwq2d",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

import Config

config :context_bot, ContextBot.ATProto.ReqClient,
  pds_url: "https://pds.test",
  session: ContextBot.ATProto.Session,
  timeout: 1_000,
  req_options: [
    plug: {Req.Test, ContextBot.ATProto.ReqClient},
    plugins: [ContextBot.ATProto.ReqClientTest.RequestCapture]
  ]

config :context_bot, ContextBot.ATProto.Session,
  timeout: 1_000,
  reauthentication_cooldown_ms: 60_000,
  req_options: [plug: {Req.Test, ContextBot.ATProto.Session}]
