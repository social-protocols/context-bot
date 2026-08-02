defmodule ContextBot.FakeClock do
  @moduledoc false

  use Agent

  def start_link(initial_time) do
    Agent.start_link(fn -> initial_time end)
  end

  def now(clock), do: Agent.get(clock, & &1)

  def advance(clock, amount, unit \\ :second) do
    Agent.get_and_update(clock, fn now ->
      advanced = DateTime.add(now, amount, unit)
      {advanced, advanced}
    end)
  end
end
