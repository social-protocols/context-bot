# Task 13 Report: Deferred Work, Recovery, and Safe Operations

## TDD evidence

- RED command: `direnv exec . mix test test/context_bot/workers/deferred_worker_test.exs test/context_bot/operations_test.exs test/context_bot_web/controllers/health_controller_test.exs test/context_bot/admission_test.exs`
- RED result: exit 2, 11/22 failed for the intended missing `DeferredWorker`, `Operations`, health aggregate, and Admission recovery-gate behavior. The other 11 tests passed, demonstrating that the failures were causal rather than fixture or compilation failures.
- Initial GREEN result: the same focused command passed 22/22.
- Scoped-audit RED: `direnv exec . mix test test/context_bot/workers/deferred_worker_test.exs:176` failed because an oldest workflow with an already-active job consumed a size-one recovery batch and starved the next missing job.
- Scoped-audit GREEN: the targeted regression passed 1/1 after active work was excluded before the batch limit; the complete focused command then passed 23/23.

## Implementation

- Added a minute-by-minute Oban cron entry for `ContextBot.Workers.DeferredWorker` on the maintenance queue.
- Deferred/recovery candidates are selected in a short `mode: :immediate` SQLite transaction. Recovery work with an active incomplete job is excluded before applying the configured bounded batch, preventing both duplicate work and starvation.
- Job insertion happens after the claim transaction. Each insert uses Oban Lite's unique-job engine inside its own short immediate transaction with infinite uniqueness over worker and URI/CID args for incomplete states.
- Recovery maps `received` to eligibility, `capturing_thread` to thread capture, `thread_ready`/`researching` to research, and `reply_ready`/`publishing` to publication. Terminal stages are not selected.
- Capacity and rate deferrals return to current eligibility and clear stale evidence. Capacity self-excludes the workflow being reconsidered.
- Budget deferrals become `thread_ready` only after their UTC `defer_until`, preserved accepted-workflow evidence, a captured canonical thread, current pending/actor/global admission gates, and the current UTC budget gate all permit resumption. Research still enforces the exact next-attempt reservation atomically.
- Added narrow read-only Admission APIs that reuse the same private pending and rolling-window queries as `admit/4`, excluding the already-admitted workflow itself.
- Added credential-free operational health aggregates for bot/session state, active queue counts, deferred counts, safe failure-category counts, current UTC-day unsettled reservations/settlements, and oldest pending age. Provider session degradation remains HTTP 200 liveness.
- Added structured attempt logging that serializes only invocation database ID, finite stage/attempt kind, attempt index, safe HTTP status, duration, and finite failure category. Extra request, client, session, header, body, identity, and token fields are never inspected or serialized.

## Scoped self-audit

- Found and corrected recovery-batch starvation caused by applying the limit before excluding already-active jobs.
- Confirmed external provider calls do not occur in claim or enqueue transactions, stage transitions remain durable before enqueue, crash gaps are repaired, budget uses UTC dates, and health/log projections do not include stored content or identity fields.

## Verification

- Focused: 23 tests passed.
- Fresh `direnv exec . just check`: formatting, warnings-as-errors compilation, Credo, ShellCheck, 279 ExUnit tests, secrets tests, and Dialyzer all passed; Dialyzer reported 0 errors.

## Commit

- Planned commit message: `feat: recover deferred context bot work`

## Formal review fix round 1

### TDD evidence

- Initial review RED for findings 1–4: the deferred-worker suite failed 7/11 for the intended causes: deferred-capacity backlog did not drain, `checking_eligibility` was not recovered, completed leased work was duplicated, cancelled/discarded histories were retried, and no matching recovery index existed.
- Findings 1–4 GREEN: the deferred-worker suite passed 11/11 after the bounded recovery and capacity changes.
- Initial findings 5–7 run was compile-blocked by a partial-patch syntax error. After correcting only that corruption, the focused suite ran 74 tests and failed exactly 6: linked health-task failure, absent eligibility/maintenance/thread/publication logs, and non-cumulative budget selection.
- Findings 5–7 GREEN: the same focused suite passed 74/74 after implementing the missing behavior.
- Broader affected-module verification passed 124/124 across operations, all five workers, admission, ATProto session handling, and the research runner.

### Corrections

- Deferred-capacity rows no longer consume active capacity. The serialized immediate transaction now admits at most the currently free slots even when backlog exceeds `MAX_PENDING`.
- Recovery scans exactly the configured candidate batch and performs only per-candidate, worker-and-URI/CID-scoped latest-job lookups; no global active-job materialization remains.
- Missing jobs recover, active jobs suppress duplicates, cancelled/discarded jobs become finite safe terminal failures, and completed research/publication jobs recover only after their claim lease expires. `checking_eligibility` now recovers through `EligibilityWorker`.
- Added the matching `(stage, received_at, id)` recovery-scan index and a persisted finite `deferred_attempt_kind` checkpoint.
- Deferred budget selection uses each workflow's actual next-attempt reservation and subtracts selected reservations cumulatively during the serialized batch.
- Health session inspection is finite and isolated in an unlinked monitored process; timeout, exit, and exception cases degrade to `unavailable` without leaking provider exception text.
- Eligibility, thread, research, publication, and maintenance execution paths now call the structured logger using only invocation ID, finite stage/kind, attempt index, duration, status, and safe failure category.

### Scoped self-audit

- Confirmed terminal recovery categories remain finite and stage-appropriate and that terminalization clears both claim leases.
- Confirmed cancelled/discarded histories are never recreated, completed jobs with fresh leases are suppressed, and expired leases recover.
- Found that the initial recovery index placed `defer_until` between `stage` and the recovery ordering columns; corrected it to `(stage, received_at, id)` so it matches the bounded recovery scan.
- Credo identified excess cyclomatic complexity in recovery classification; split the state handling into small helpers without changing behavior.

### Verification

- Fresh `direnv exec . just check`: formatting, warnings-as-errors compilation, strict Credo, ShellCheck, 291 ExUnit tests, secrets tests, and Dialyzer all passed; Dialyzer reported 0 errors.

### Commit

- Planned commit message: `fix: bound workflow recovery`
