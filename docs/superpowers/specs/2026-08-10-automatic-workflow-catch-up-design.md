# Automatic Workflow Catch-up and Dry-run Attachment

**Date:** 2026-08-10  
**Status:** Proposed

## Goal

Make durable workflow recovery the normal startup behavior instead of requiring a special
`resume-dry-run` command. Starting a local dry run will recover and process all pending local
dry-run work that is safe and due, while the foreground command attaches to an existing matching
invocation rather than creating a duplicate paid request.

The public bot retains the same general recovery policy when it starts. Local dry-run mode remains
strictly read-only with respect to ATProto and never starts public queues, polling, authentication,
or publication.

## Operator behavior

The interface remains:

```bash
just dry-run <bluesky-post-url-or-at-uri> "What's the context?"
```

There is no dry-run-specific resume command. The command:

1. starts the base application without Oban consumers;
2. validates and normalizes the post reference and question;
3. atomically finds or creates the matching durable dry-run invocation;
4. reports whether it attached to existing work or created new work;
5. runs safe startup recovery and due-deferral reconciliation;
6. starts the local-only `dry_thread` and `dry_research` queues, which process every available
   pending dry-run job; and
7. displays progress for the selected invocation until it settles or the operator interrupts it.

Other pending dry runs continue in the background during the command. Research remains serialized
by the queue limit, and every Anthropic attempt remains subject to the configured daily budget.
Interrupting the foreground command stops the local runtime cleanly; it does not cancel or erase
durable workflow state.

## Matching and idempotent creation

Two local requests match only when both of these fields are exactly equal after input validation:

- the normalized, DID-based target AT URI; and
- the question text, byte for byte.

Whitespace and capitalization are not rewritten. A matching invocation is reusable only when
`dry_run` is true and its stage is nonterminal. The terminal stages `complete`, `failed`, and
`ineligible` never block a deliberate repeat, so rerunning a completed request creates a new
invocation.

`ContextBot.Workflow.Store` performs lookup and insertion inside one SQLite `BEGIN IMMEDIATE`
transaction. If a matching nonterminal invocation exists, it returns that row without inserting
another thread job. Otherwise it inserts the invocation and first `dry_thread` job atomically.
This serializes concurrent local commands without a schema migration or a permanent uniqueness
constraint.

If historical data already contains multiple matching nonterminal invocations, the lookup selects
the newest one. Existing duplicates are not silently merged or deleted by ordinary catch-up;
operational cleanup must terminalize the unwanted row and cancel its incomplete jobs explicitly.

## Startup sequencing and race prevention

The local runtime is split into two explicit phases.

### Base application phase

The base phase verifies `BOT_ENABLED=false`, starts the Repo and public HTTP client dependencies,
and confirms that no authenticated session, mention poller, public worker, or Oban instance is
running. It does not dispatch queued work.

The command then normalizes its target and completes the transactional find-or-create operation.
Doing this before consumers start prevents an older matching invocation from completing between
startup recovery and attachment, which would otherwise cause the command to create a duplicate.

### Catch-up and worker phase

After the foreground invocation is known, the worker phase:

- applies the existing interruption recovery matrix to abandoned work;
- reconsiders due budget deferrals for dry-run invocations only;
- preserves future budget deferrals without making a request;
- enqueues recovered dry-run research only on `dry_research`; and
- starts minimal Oban consumers for `dry_thread` and `dry_research`, each with concurrency one.

The worker phase has no public queues and no cron plugin. Due-deferral reconciliation is a one-shot
startup operation, so local catch-up does not need to start the general maintenance queue. The
shared deferred-work logic chooses a queue from the durable `dry_run` flag: `dry_research` for
local runs and `research` for public invocations. Local mode filters candidates before claiming
them, so it cannot advance public admission or enqueue public work.

All startup reconciliation happens before Oban consumers start. Failure in recovery or
due-deferral reconciliation prevents consumer startup and returns a finite, safe error.

## What “all pending work” means

Once local consumers start, they process all available, retryable, or newly recovered jobs on the
two dry-run queues, not only the invocation shown by the foreground progress renderer.

The following state is intentionally not executed:

- future `deferred_budget` work remains deferred until its timestamp is due;
- an Anthropic attempt durably marked `sent` without a committed response envelope is
  terminalized as `provider_response/interrupted_after_send` and is never replayed;
- terminal invocations remain unchanged; and
- public invocations and public queues remain stopped in local dry-run mode.

This keeps “process all” subordinate to the existing safety and spend rules. It does not mean
bypassing the daily budget or retrying an ambiguous provider request.

## Public-bot behavior

The public application continues to run shared startup recovery before normal Oban queues start,
then uses its maintenance worker for due deferrals and runtime orphan checks. The catch-up rules
are workflow-general; only the set of queues and candidates allowed by the current runtime mode
differs.

A later refactor may expose one coordinator for public startup and local startup, but this change
does not replace the already-tested public supervision order. It extends the same durable policy
to the local command without weakening its publication boundary.

## Progress, interruption, and results

The progress display follows only the selected invocation. When the command reuses existing work,
it prints the existing `dry_run_id` and an attachment indicator before rendering progress. Other
pending jobs may run first because queue order is durable and oldest-first; the selected invocation
can therefore remain queued while catch-up drains older work.

SIGINT and SIGTERM retain the existing shell-to-BEAM shutdown bridge. On interruption, the command
prints the durable invocation ID, stops safe Oban consumers, and exits nonzero. The next dry-run
command performs catch-up again. No signal path reconstructs jobs or retries provider exposure
directly.

## Current duplicate cleanup

The current development database contains two matching unfinished invocations created while signal
handling was being repaired. As an explicit one-time operation after this implementation is
verified, invocation 2 will be marked `failed` with a finite `invalid_input` category and safe
detail reason `superseded_duplicate_dry_run`; its incomplete Oban jobs will be cancelled.
Invocation 3 will remain pending and become the row selected by the next matching command.

This cleanup will not start Oban, fetch Bluesky, or call Anthropic. It preserves both rows for
auditability and avoids paying twice for the same test.

## Alternatives considered

### Dedicated `resume-dry-run <id>` command

This is explicit, but it creates dry-run-only recovery semantics and asks operators to understand
job reconstruction. It is unnecessary because SQLite and Oban already hold the durable state.

### Always create a new invocation, then run catch-up

This is simple but can repeat identical paid work whenever an operator retries a command after an
interruption. It caused the duplicate state in the current database.

### Database uniqueness constraint

A persistent fingerprint constraint could eliminate duplicate active requests, but terminal rows
must remain repeatable and SQLite partial-index semantics would add migration and lifecycle
complexity. A serialized lookup-and-insert transaction provides the required single-operator and
concurrent-process safety for the proof of concept.

## Testing and acceptance

Behavior-first tests will cover:

- matching nonterminal dry runs are reused without another invocation or thread job;
- terminal matching runs allow a new invocation;
- target normalization happens before matching;
- different question bytes produce different runs;
- lookup and creation occur inside an immediate transaction;
- workers cannot start before the foreground invocation is selected;
- startup recovery runs before local queue consumers;
- all existing dry queue jobs are eligible to execute, not only the foreground job;
- due dry budget deferrals move to `dry_research`, while future deferrals remain unchanged;
- local catch-up never claims public deferred work or starts a public queue;
- ambiguous sent Anthropic attempts remain terminal and are not replayed;
- recovery failure prevents worker startup; and
- interruption leaves the selected invocation durable for the next automatic catch-up.

The complete verification gate must pass. Manual acceptance will inspect the development database
after the one-time duplicate cleanup, then run the same `just dry-run` command and confirm it prints
`dry_run_id=3`, reports attachment to existing work, processes pending safe work within budget, and
performs no ATProto write.
