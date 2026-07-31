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

## Fix Round 1: Durable Publication Fencing

### Findings addressed

- Added a durable publication lease with an owner token and microsecond timestamp. The same Oban
  job renews its lease across retries, a different live job is rejected, and a stale lease may be
  taken over. Every PDS GET and PUT boundary renews/fences the exact token; completion and failure
  transitions are also atomically token-fenced, so a stale owner cannot publish or replace the
  winner's terminal outcome.
- Froze the validated reply repository during the `ResearchWorker` handoff. `ReplyWorker` now uses
  only the persisted repository, rkey, and record; missing or corrupt frozen intent fails before
  provider I/O, and runtime configuration drift cannot redirect a retry.
- Reconciled all ambiguous non-auth, non-permanent PUT failures by GET, including exposed transport
  failures on the final attempt. Permanent PDS 403 errors now use `publication_auth`.
- Added strict, bounded `Retry-After` parsing for rate-limit backoff, with deterministic default
  backoff for missing, malformed, or negative values.

Migration `20260729004000_add_publication_claim_and_repo.exs` adds nullable `reply_repo`,
`publication_claim_token`, and `publication_claimed_at` columns plus a claim-token index. Nullable
columns preserve compatibility with existing rows, while the worker treats absent frozen intent as
a finite pre-I/O failure.

### TDD evidence

RED command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs test/context_bot/workers/research_worker_test.exs
```

Result before production changes: `18/26 passed`; eight intended regressions failed for missing
repository freeze, same-job lease resumption, live-owner exclusion, stale takeover/fencing,
configuration-drift safety, exposed transport reconciliation, permanent-403 classification, and
strict `Retry-After` handling.

GREEN focused command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs test/context_bot/workers/research_worker_test.exs test/context_bot/workflow/store_test.exs
```

Result: `45 passed`, exit 0.

The single authorized scoped audit confirmed that all PDS GET/PUT call sites are reached only after
an atomic lease renewal, all publication terminal writes use the exact-token transition, the reply
worker has no runtime repository fallback, and ambiguous PUT outcomes enter reconciliation.

### Full gate

Command:

```text
direnv exec . just check
```

Result: exit 0. Formatting, warnings-as-errors compilation, Credo strict, ShellCheck, and secrets
tests passed; ExUnit reported `266 passed`; Dialyzer reported zero errors, zero skipped warnings,
and zero unnecessary skips.

### Fix commit and files

Commit message: `fix: fence Bluesky reply publication`

- `lib/context_bot/workers/reply_worker.ex`
- `lib/context_bot/workers/research_worker.ex`
- `lib/context_bot/workflow/invocation.ex`
- `lib/context_bot/workflow/store.ex`
- `priv/repo/migrations/20260729004000_add_publication_claim_and_repo.exs`
- `test/context_bot/workers/reply_worker_test.exs`
- `test/context_bot/workers/research_worker_test.exs`
- `.superpowers/sdd/2026-07-29-context-bot-poc/task-12-report.md`

### Remaining concerns

- No open blocker. Lease duration is configurable for tests and defaults to five minutes in
  production; takeover remains safe because every provider boundary and terminal transition is
  fenced against the current persisted token.

## Fix Round 2/5: Strict Retry-After Delta-Seconds

The contextual backoff parser now validates the complete Retry-After value against
`\A[0-9]+\z` before integer conversion. This rejects signed forms such as `+47` and `-0`, which
`Integer.parse/1` previously accepted even with an empty remainder, while preserving the default
for whitespace or malformed values and the existing 3,600-second cap for arbitrarily large digit
strings.

### TDD evidence

Focused RED command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs
```

Result before the parser change: `20/22 passed`. The two intended failures showed `+47` returning
`47` instead of the default `15`, and `-0` returning `0` instead of `15`.

Focused GREEN command:

```text
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs
```

Result after digits-only validation: `22 passed`, exit 0. The same test group covers valid digits,
leading and trailing whitespace, malformed suffixes, nil, the ordinary upper bound, and a very
large all-digit value.

### Full gate

```text
direnv exec . just check
```

Result: exit 0. Formatting, warnings-as-errors compilation, Credo strict, ShellCheck, and secrets
tests passed; ExUnit reported `268 passed`; Dialyzer reported zero errors, zero skipped warnings,
and zero unnecessary skips.

### Fix commit

Commit message: `fix: parse ATProto retry delays strictly`
