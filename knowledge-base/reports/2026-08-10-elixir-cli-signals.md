# Elixir CLI signal handling

**Date:** 2026-08-10
**TL;DR:** Elixir 1.20 cannot install a `System.trap_signal/3` callback for
SIGINT. A terminal Mix task that needs graceful Ctrl-C handling must keep the
BEAM from acting on SIGINT and translate it to a supported signal such as
SIGTERM in a foreground shell wrapper.

## Context

The durable dry-run command failed immediately after creating invocation `3`
with `unable to install dry-run signal handlers`. It ran the BEAM with `+B` to
disable the Erlang BREAK menu and attempted to trap both SIGINT and SIGTERM in
`ContextBot.DryRun.Interrupts`.

## Investigation

Running `System.trap_signal(:sigint, token, callback)` directly under the
project's Devbox Elixir 1.20.2 / OTP 28.5 environment raised a
`FunctionClauseError`. The accepted signals in Elixir's `System` source do not
include SIGINT. OTP's `os:set_signal/2` specification likewise excludes
SIGINT.

The local `erl` manual documents the relevant BREAK modes:

- `+B` or `+B d` disables the BREAK handler.
- `+B i` makes the emulator ignore the BREAK signal.

A focused experiment confirmed that `+B i` leaves the BEAM alive after SIGINT
while `System.trap_signal/3` successfully delivers SIGTERM to a callback.

## Findings

`System.trap_signal/3` is appropriate for SIGTERM in a Mix task, but it cannot
provide Ctrl-C handling directly. The safe composition is:

1. Run the BEAM with `+B i` so terminal SIGINT does not open the BREAK menu or
   terminate the VM.
2. Keep a foreground Bash wrapper that traps SIGINT and SIGTERM.
3. Have that wrapper send SIGTERM to the Mix child and wait for it.
4. Let the Elixir SIGTERM callback notify the task owner, which performs normal
   progress cleanup and durable worker shutdown outside the signal callback.

Background shell tests need to reset SIGINT before `exec` because Bash gives
asynchronous children an ignored SIGINT disposition when job control is off.

## Implications

Do not add SIGINT to `System.trap_signal/3` calls. Test the real runtime handler
installation, not only injected callback functions. Test the wrapper as a
process boundary so argument forwarding, bot disabling, signal translation,
graceful waiting, and exit-status propagation stay covered without provider
access.
