defmodule ContextBot.DryRun.InterruptsTest do
  use ExUnit.Case, async: true

  alias ContextBot.DryRun.Interrupts

  test "installs scoped SIGINT and SIGTERM callbacks that only notify the owner" do
    owner = self()

    trap = fn signal, id, callback ->
      send(owner, {:trapped, signal, id, callback})
      {:ok, id}
    end

    assert {:ok, token} = Interrupts.install(owner, trap_signal: trap)
    assert is_reference(token)

    assert_receive {:trapped, :sigint, ^token, sigint_callback}
    assert_receive {:trapped, :sigterm, ^token, sigterm_callback}
    assert :ok = sigint_callback.()
    assert_receive {:context_bot_interrupt, :sigint}
    assert :ok = sigterm_callback.()
    assert_receive {:context_bot_interrupt, :sigterm}
  end

  test "removes both handlers even when one unregister call fails" do
    owner = self()
    token = make_ref()

    untrap = fn signal, id ->
      send(owner, {:untrapped, signal, id})
      if signal == :sigint, do: {:error, :not_registered}, else: :ok
    end

    assert :ok = Interrupts.remove(token, untrap_signal: untrap)
    assert_receive {:untrapped, :sigint, ^token}
    assert_receive {:untrapped, :sigterm, ^token}
  end

  test "rejects invalid owners and callbacks" do
    assert {:error, :invalid_input} = Interrupts.install(:not_a_pid)
    assert {:error, :invalid_input} = Interrupts.install(self(), trap_signal: :not_a_function)
    assert :ok = Interrupts.remove(make_ref(), untrap_signal: :not_a_function)
  end
end
