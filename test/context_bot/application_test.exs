defmodule ContextBot.ApplicationTest do
  use ExUnit.Case, async: false

  alias ContextBot.{Application, Settings}
  alias ContextBot.ATProto.Session
  alias ContextBot.Mentions.Poller

  test "an enabled bot supervises its session after Oban" do
    settings =
      Settings.load(
        bot_enabled: true,
        bot_did: "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        bot_handle: "contextbot.test",
        bot_pds_url: "https://pds.test",
        anthropic_daily_budget_usd: "10.00"
      )

    assert [{Oban, oban_options}, Session, Poller] = Application.bot_children(settings)
    assert oban_options == Elixir.Application.fetch_env!(:context_bot, Oban)

    assert {:ok, {_flags, child_specs}} =
             Supervisor.init(Application.bot_children(settings), strategy: :one_for_one)

    assert Enum.map(child_specs, & &1.id) == [Oban, Session, Poller]
  end

  test "a disabled bot does not supervise bot-only children" do
    assert Application.bot_children(Settings.load(bot_enabled: false)) == []
  end
end
