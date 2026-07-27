defmodule ContextBot.Repo do
  use Ecto.Repo,
    otp_app: :context_bot,
    adapter: Ecto.Adapters.SQLite3
end
