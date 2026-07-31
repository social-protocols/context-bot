# Task 12 Report: Exactly-Once Reply Publication

## Outcome

Implemented a durable `ReplyWorker` that converges each frozen Bluesky reply intent at its one
deterministic `(repo, collection, rkey)`. It atomically advances `reply_ready` to `publishing`,
always GETs before PUT, relies on the existing ReqClient create-only `swapRecord: nil` request,
and accepts a PDS URI/CID only after a GET returns the exact expected URI and full record.

Existing exact records complete without PUT. Record or coordinate mismatches terminate as
`failed/publication_conflict` and are never overwritten. Authorization failures terminate as
`failed/publication_auth`; after credential repair, an operator must explicitly reset the terminal
markers and stage to `reply_ready` while retaining the same frozen rkey/record. No automatic auth
retry or fallback post exists.

Timeout and `InvalidSwap` writes are reconciled by GET. Missing reconciliation results and other
transient errors retry through Oban without changing intent. The final permitted attempt stores a
finite `retry_exhausted` publication failure so a discarded job cannot leave an invocation stuck
in `publishing`.

## Concurrency and fencing

The short SQLite transition is the local claim for fresh `reply_ready` work. Resumptions already
at `publishing` may overlap, so the deterministic repository coordinate and PDS create-only swap
are the visibility fence: concurrent PUTs target the identical URI and at most one can create the
record. Every contender then GET-reconciles; only exact equality can complete. The concurrency
test forces two publishing jobs to observe a missing record before either PUT and proves the fake
PDS contains exactly one visible record with the frozen value.

No new schema was required. Repeated jobs after completion issue no provider request.

## TDD evidence

### RED

The initial behavior-first suite was run before the worker existed:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs
```

Result: `0/8 passed`; every test failed for the intended missing `ReplyWorker.perform/1` behavior.

After the first green cycle, a final-attempt regression was added for transient GET, PUT, and
post-PUT reconciliation failures. Its focused run failed with `{:error, :timeout}` instead of a
finite terminal state, proving the discarded-job lifecycle gap before the implementation changed.

### GREEN

Fresh focused command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs
```

Result: `9 passed`, exit 0.

Expanded contract/integration command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs test/context_bot/atproto/req_client_test.exs test/context_bot/workers/research_worker_test.exs
```

Result: `35 passed`, exit 0.

Coverage includes GET-missing/create/reconcile, pre-existing exact records, repository/collection/
rkey differences, changed and extra record fields, timeout and `InvalidSwap` reconciliation, exact
retry intent reuse, auth intervention state, bounded exhaustion at every retry point, repeated
jobs, and forced concurrent resumptions.

## Full gate

Command:

```text
direnv exec . just check
```

Result: exit 0.

- format and shell-format checks passed;
- compilation with warnings as errors passed;
- Credo strict and ShellCheck found no issues;
- ExUnit: `255 passed`, 0 failures;
- secrets shell tests passed;
- Dialyzer: 0 errors, 0 skipped, 0 unnecessary skips.

## Commit

Commit message: `feat: publish exactly one Bluesky reply`

## Files changed

- `lib/context_bot/workers/reply_worker.ex`
- `test/context_bot/workers/reply_worker_test.exs`
- `.superpowers/sdd/2026-07-29-context-bot-poc/task-12-report.md`

## Concerns

- No open blocker.
- Concurrent `publishing` resumptions may both attempt the same create-only PUT, but cannot create
  two visible records because both use the same persisted repository coordinate and exact record.
- The existing finite failure taxonomy has no separate publication-exhaustion category, so bounded
  retry exhaustion is recorded as `publication_conflict` with safe reason `retry_exhausted`.
