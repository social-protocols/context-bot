# Task 11 Report: Durable Budgeted Claude Research

## Outcome

Implemented a durable, budgeted Claude research runner and Oban research worker. Every Anthropic
POST is ordered as a committed budget reservation, a committed sent marker, an external request
outside any database transaction, and an atomic raw-envelope plus response marker write before
decoding or deciding. Restart reconciliation reuses exact attempt keys and persisted request
checkpoints, retains uncertain spend, and bounds every retry, continuation, tool-use, and repair
path.

The worker claims research durably, performs provider work outside transactions, and atomically
freezes the full conversation checkpoint, per-attempt usage evidence, validated reply text, exact
ATProto record/rkey, and the future `ReplyWorker` job. No PDS write occurs in this task.

Commit message: `feat: run durable budgeted Claude research`

## Behavior delivered

- Initial requests are durably checkpointed before the first reservation.
- Attempt keys remain monotonic and stable across restarts; a reserved attempt is reused rather
  than re-reserved.
- A sent attempt without a recorded envelope becomes indeterminate. It can be replayed only
  through the configured bounded safe-replay path, under a new reservation.
- Complete tagged response envelopes are stored in arrival order. Storage and
  `response_recorded_at` are one short immediate transaction and roll back together on failure.
- HTTP calls, retry delays, provider decoding, pricing, and reply selection happen outside
  database transactions.
- Returned 429 and 5xx envelopes are persisted before retry decisions. Both delta-seconds and
  strict IMF-fixdate `Retry-After` values are honored, capped by the configured retry maximum;
  absent or invalid values use bounded exponential delay.
- Known transport errors are retried only within the configured cap. A timeout is replayed at most
  once, retaining the original reservation as exposure.
- 401/403 map to provider authentication failure. Permanent 4xx, malformed JSON, invalid provider
  shapes, unknown blocks, and oversized provider responses fail closed.
- `pause_turn` continuations append complete opaque assistant content, preserve unknown blocks,
  and reconstruct pending server-tool context from persisted messages.
- Search, fetch, and continuation caps are enforced cumulatively across all responses.
- Every settled successful HTTP attempt checkpoints opaque per-attempt usage and cumulative token
  totals, including attempts that later end in invalid reply, repair failure, or tool-cap failure.
- Exactly one append-only length repair is allowed. A crash after persisting the repair request but
  before its reservation resumes the repair request rather than reclassifying the primary result.
- Cache misses remain valid billable responses and retain exact usage evidence.
- Settings now validate the pinned model, web fetch/search limits, continuation cap, retry count,
  retry delays, and ordering between base and maximum retry delay.

## Crash-window and concurrency guarantees

Crash hooks and restart tests cover these durable boundaries:

1. after reservation, before the sent marker;
2. after the sent marker, before/during the HTTP call;
3. after HTTP return, before raw-envelope persistence;
4. after atomic raw-envelope persistence, before decoding and settlement;
5. after a persisted repair request, before its attempt reservation.

Recovery always consults the budget ledger plus persisted request/response checkpoints. It does
not infer attempt identity from the response-array length. Raw storage failures never leave a
response marker behind, while completed raw writes are decoded on restart without another POST.

Research ownership is protected independently of Oban queue concurrency by a persisted claim
token and timestamp. Stable `research-job-<id>` tokens let the same Oban job resume immediately
after a crash; a different duplicate job is ignored while the lease is live and may take over only
after the bounded lease expires. Tests cover simultaneous duplicate jobs, same-job crash recovery,
duplicate blocking, and stale-lease takeover. The new lease columns use the next ordered migration
timestamp.

## TDD evidence

### RED

Behavior-first tests were added in small slices and observed failing for the intended reasons:

- the runner and worker modules were initially absent;
- crash recovery initially repeated or lost work at reservation, sent, response, and repair
  checkpoints;
- continuation, tool aggregation, and repair behavior were initially unimplemented;
- the required settings and validation were missing;
- integer and HTTP-date `Retry-After` handling and bounded transport replay were missing;
- a crash after the repair checkpoint did not resume the repair request;
- two jobs could concurrently enter a persisted `:researching` invocation;
- terminal invalid repair paths omitted the second settled attempt from durable usage evidence;
- the full gate caught an unavailable OTP HTTP-date helper, proving the implementation was not
  portable to the repository's pinned runtime.

### GREEN

The runner/worker suites now cover exact ordering, attempt recovery, response durability,
storage-cap rollback, budget settlement, 429/5xx and transport retry boundaries, repair recovery,
opaque continuations, unknown-block retention, cache misses, aggregate caps, atomic publication
handoff, idempotence, provider failure mapping, and research-lease concurrency.

Fresh focused command:

```text
direnv exec . mix test test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs
```

Result: `26 passed`, exit 0.

The strict local IMF-fixdate replacement was also exercised directly by the existing HTTP-date
retry regression: `1 passed`, exit 0.

## Full gate

The first complete gate found one Credo aliasing suggestion in the new worker test. After that
mechanical fix, the next run passed format, lint, ShellCheck, compilation, all tests, and shell
tests, then Dialyzer identified the unavailable `:httpd_util.convert_request_date/1` call. It was
replaced with a strict local IMF-fixdate parser; the focused regression and Dialyzer then passed.

Fresh final command:

```text
direnv exec . just check
```

Result: exit 0.

- format and shell-format checks passed;
- compilation with warnings as errors passed;
- Credo strict and ShellCheck found no issues;
- ExUnit: `234 passed`, 0 failures;
- secrets shell tests passed;
- Dialyzer: 0 errors, 0 skipped, 0 unnecessary skips.

## Files changed

- `lib/context_bot/research/runner.ex`
- `lib/context_bot/workers/research_worker.ex`
- `lib/context_bot/settings.ex`
- `lib/context_bot/workflow/invocation.ex`
- `lib/context_bot/workflow/store.ex`
- `priv/repo/migrations/20260729002000_add_research_claim_lease.exs`
- `test/context_bot/research/runner_test.exs`
- `test/context_bot/workers/research_worker_test.exs`
- `test/context_bot/settings_test.exs`
- `test/fixtures/anthropic/pause_then_success.json`
- `test/fixtures/anthropic/repair_success.json`
- `test/fixtures/anthropic/tool_success.json`
- `test/fixtures/anthropic/unknown_blocks.json`
- `.superpowers/sdd/2026-07-29-context-bot-poc/task-11-report.md`

## Concerns

- No open blocker. The default research claim lease is six hours: long enough to avoid ordinary
  duplicate provider work, bounded so abandoned jobs can eventually be recovered. Same-job Oban
  retries do not wait for lease expiry.
- A provider response rejected at the HTTP client's body-size boundary has no complete raw body to
  preserve and therefore fails closed; its sent reservation remains retained as exposure.
- HTTP-date retry parsing intentionally accepts the current IMF-fixdate HTTP-date form. Invalid or
  obsolete date forms fall back to the bounded exponential policy.

## Fix Round 1: Claim Fencing, Status Classification, and Raw BLOB Ledger

### Findings addressed

- The acquired research claim token now travels from `ResearchWorker` into `Runner`. Every
  provider-capable mutation is fenced atomically against the persisted `:researching` stage and
  exact token: initial/request/usage checkpoints, reservation, reservation adoption, sent marker,
  indeterminate marking, reconciliation, settlement, raw response plus marker, final reply
  handoff, budget deferral, and terminal failure.
- A current claim is renewed immediately before the Anthropic client boundary. If ownership is
  lost after the sent marker but before that check, the stale owner returns `:stale_claim` without
  making the POST. Mutations after an in-flight response returns are independently fenced.
- Each budget entry records the token that owned its reservation. A new owner may atomically adopt
  a reserved-but-unexposed attempt. A sent/exposed attempt is instead retained as indeterminate,
  and any replay uses a new monotonically sequenced reservation and attempt key.
- `ResearchWorker` treats `:stale_claim` as a finite no-op. Token-aware workflow transitions ensure
  an old worker cannot win reply handoff, defer, or fail after another job takes over. Stable Oban
  job tokens still allow legitimate same-job crash recovery.
- HTTP status is classified only after the raw envelope is durable and before provider-body JSON
  decoding. Malformed, empty, HTML, and invalid-UTF-8 401/403 bodies still yield provider auth;
  other 4xx responses terminate as provider response failures; 429/5xx responses still retry and
  honor `Retry-After`. Only 2xx interpretation requires JSON.
- Raw envelopes now live in an ordered normalized SQLite ledger. `raw_body` is a BLOB, so arbitrary
  bytes round-trip exactly. Envelope metadata is encoded before the immediate transaction and
  decoded only after it; the transaction performs no provider JSON normalization, provider decode,
  or full-ledger reserialization.
- The raw row insert, cumulative storage-limit check, and matching
  `response_recorded_at` marker remain one immediate transaction. Indexed invocation, budget-entry,
  attempt-key, kind, and status columns keep order and attempt tags queryable. The old invocation
  JSON column is no longer loaded by ordinary invocation queries; a read-only fallback preserves
  existing pre-migration rows where needed.

### Migration notes

`20260729003000_create_anthropic_response_envelopes.exs` is the next ordered migration. It:

- adds `research_claim_token` to `api_budget_entries` so reserved attempts have a durable owner;
- creates `anthropic_response_envelopes` with invocation/budget foreign keys, unique budget-entry
  and attempt-key indexes, an invocation/order index, queryable kind/status fields, pre-encoded
  metadata BLOB, exact raw-body BLOB, and an atomic per-row storage-byte contribution;
- leaves the legacy invocation response column in place only for read compatibility. All new
  response writes use the normalized ledger.

### TDD evidence

Each review finding was reproduced before its production change:

- fencing RED: `0/4` runner regressions showed old owners still sending reserved/sent attempts,
  appending after HTTP return, and settling/checkpointing after takeover;
- worker terminal RED: `0/1` showed an old worker reaching `reply_ready` after another job acquired
  the lease;
- status-order RED: `0/2` showed non-2xx bodies reaching the decoder and malformed retryable
  responses terminating rather than retrying;
- ledger RED: `0/2` at the new token-aware boundary covered invalid UTF-8 BLOB round-trip and
  cumulative-limit/marker atomicity;
- checkpoint RED: `0/2` reproduced takeover exactly after settlement and immediately before a
  continuation request checkpoint;
- scoped-audit RED: a takeover after the sent marker still allowed the stale owner to reach the
  Anthropic client before raw persistence rejected it.

The corresponding GREEN runs proved stale owners stop without POST/mutation/handoff, current
owners recover, exposed replay uses a new key, malformed non-2xx classification is independent of
JSON, arbitrary bytes remain exact, storage-limit rollback leaves no marker, and both usage and
request checkpoints are fenced. The final expanded focused suites were:

```text
direnv exec . mix test test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs
```

Result: `36 passed`, exit 0.

```text
direnv exec . mix test test/context_bot/workflow/store_test.exs test/context_bot/research/budget_test.exs
```

Result: `26 passed`, exit 0.

### Scoped static audit

One bounded static audit reviewed only the formal findings and changed call paths. It found the
post-sent/pre-client window described above; the behavior-specific regression failed because the
client received the call, then passed after an exact-token renewal was added immediately before
POST. Targeted Credo over all changed modules and tests then found no issues. No open-ended review
cycle was performed.

### Full gate

The first full gate passed formatting, lint, warnings-as-errors compilation, all tests, and shell
tests, then Dialyzer reported that five legacy Budget wrapper specs excluded their intentional
internal `nil` owner token. Widening the shared token type to match the already-tested compatibility
path resolved all derivative warnings.

Fresh final command:

```text
direnv exec . just check
```

Result: exit 0.

- format and shell-format checks passed;
- compilation with warnings as errors passed;
- Credo strict and ShellCheck found no issues;
- ExUnit: `246 passed`, 0 failures;
- secrets shell tests passed;
- Dialyzer: 0 errors, 0 skipped, 0 unnecessary skips.

Fix commit message: `fix: fence durable research execution`
