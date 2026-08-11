# Dry-run process fencing and launch-race testing

**Date:** 2026-08-11
**TL;DR:** Registered processes and `Oban.whereis/1` cannot fence independent Mix VMs. A
database-path `flock` held by an owned Port provides crash-releasing exclusivity, while the shell
launch race needs an explicit test seam rather than an inherited `BASH_ENV` DEBUG trap.

## Context

Automatic dry-run catch-up starts recovery and local-only Oban queues after attaching to durable
work. Two simultaneous `just dry-run` commands use independent BEAM VMs, so VM-local process names
do not prevent both commands from recovering the same database and starting consumers. The shell
test for interruption between `mix ... &` and assigning `$!` was also intermittently returning
SIGTRAP/status 133 even though production installs no DEBUG trap.

## Investigation

The Devbox `flock` 0.4.0 package was exercised from three independent OTP 28 VMs with the command
shape `flock -x -n -o -E 75 LOCK ABSOLUTE_CAT`. A nonce sent through an Elixir Port and echoed by
`cat` proved that the command was alive and owned the lock. A second VM received conflict status
75. After SIGKILL of the first VM, a third acquired immediately, with no lingering `flock` or `cat`
process retaining ownership.

The implementation derives the lock filename from `Path.expand(configured_database)` so separate
worktrees and SQLite databases do not contend. The Port-owning process monitors and links the CLI
process. Acquisition occurs only after the transactional dry-run find-or-create operation, and
release occurs only after the safe Oban supervisor has stopped and a monitor confirms `:DOWN`.
Oban remains linked to the CLI during execution so an unexpected consumer-runtime crash cannot
leave the lock held with no workers; the shutdown path unlinks only immediately before its
monitored graceful-or-forced stop. A real process-boundary test creates an isolated migrated SQLite
database, releases two Mix VMs through one gate, observes one `:created` and one `:attached`
disposition for the same invocation, verifies one invocation and one job, then kills the owner and
observes contender takeover.

A contender observes rather than executes its selected row. It treats a due budget deferral as
pending while another owner may still reconcile it. After takeover, it cancels that special
observer before recovery and starts a fresh ordinary observer, allowing a due row that remains
unaffordable after reconciliation to report `deferred_budget` promptly.

For the wrapper flake, the inherited `BASH_ENV` DEBUG hook also ran in the synthetic background
`mix` Bash process and could kill it with SIGTRAP. Replacing that injection with
`CONTEXT_BOT_TEST_INTERRUPT_BEFORE_PID=1`, checked immediately after `mix ... &` and before
`context_bot_child_pid=$!`, isolates the intended race. The seam self-signals `$BASHPID` and lets
the existing pending-interrupt path forward TERM and reap the child. The test passed repeatedly
under both Devbox Bash 5.3 and Homebrew Bash 5.2; status 133 was never accepted or retried.

## Findings

- SQLite transactions deduplicate durable preparation, but they do not serialize recovery and
  Oban execution after the transaction commits; a separate process-owner fence is required.
- A Port handshake distinguishes successful lock ownership from a merely spawned utility, and a
  dedicated conflict exit status keeps contention separate from lock setup failure.
- The lock must remain owned through worker shutdown. Contenders may observe their selected row and
  retry ownership, but cannot invoke recovery or start Oban before takeover.
- A contender and an owner need different due-deferral settlement semantics; switch observers at
  takeover so budget exhaustion does not become a full foreground timeout.
- Shell DEBUG-trap injection is not process-local when exported through `BASH_ENV`; it changes the
  behavior of child Bash programs and is unsuitable for a precise parent-wrapper launch race.

## Implications

Future local runtimes that can share the same SQLite database must use the same database-derived
owner boundary before startup recovery. Keep the owner utility in Devbox, verify acquisition with a
bounded protocol, preserve crash coupling while workers run, and confirm worker death before
unlocking. Test crash release across real OS processes. For shell launch-race coverage, prefer a
narrowly placed explicit seam and verify it under the supported modern Bash versions.
