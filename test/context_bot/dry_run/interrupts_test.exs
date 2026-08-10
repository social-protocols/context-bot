defmodule ContextBot.DryRun.InterruptsTest do
  use ExUnit.Case, async: false

  alias ContextBot.DryRun.Interrupts

  test "installs and removes its signal handler on the supported runtime" do
    assert {:ok, token} = Interrupts.install(self())
    assert :ok = Interrupts.remove(token)
  end

  test "installs a scoped SIGTERM callback that only notifies the owner" do
    owner = self()

    trap = fn signal, id, callback ->
      send(owner, {:trapped, signal, id, callback})
      {:ok, id}
    end

    assert {:ok, token} = Interrupts.install(owner, trap_signal: trap)
    assert is_reference(token)

    assert_receive {:trapped, :sigterm, ^token, sigterm_callback}
    refute_receive {:trapped, :sigint, ^token, _callback}
    assert :ok = sigterm_callback.()
    assert_receive {:context_bot_interrupt, :sigterm}
  end

  test "removes the SIGTERM handler" do
    owner = self()
    token = make_ref()

    untrap = fn signal, id ->
      send(owner, {:untrapped, signal, id})
      :ok
    end

    assert :ok = Interrupts.remove(token, untrap_signal: untrap)
    assert_receive {:untrapped, :sigterm, ^token}
    refute_receive {:untrapped, :sigint, ^token}
  end

  test "rejects invalid owners and callbacks" do
    assert {:error, :invalid_input} = Interrupts.install(:not_a_pid)
    assert {:error, :invalid_input} = Interrupts.install(self(), trap_signal: :not_a_function)
    assert :ok = Interrupts.remove(make_ref(), untrap_signal: :not_a_function)
  end
end
