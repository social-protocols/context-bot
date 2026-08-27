defmodule ContextBot.Runtime.DrainTest do
  use ExUnit.Case, async: false

  alias ContextBot.Runtime.Drain

  test "begin is safe when the poller and Oban are not running" do
    assert Process.whereis(ContextBot.Mentions.Poller) == nil
    assert Drain.begin() == :ok
  end
end
