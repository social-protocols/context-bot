# Context Bot Operational Hardening Design

**Status:** Approved for implementation on 2026-08-10

## Summary

Context Bot will separate machine-readable operational logs from human-facing dry-run progress,
recover interrupted workflow work without duplicating ambiguous paid requests, and reduce the
ordinary cost of Claude research. The same recovery policy applies to local dry runs and public
bot invocations.

The triggering dry run demonstrated all three needs. The thread job completed, the research job
sent one Anthropic request, and the foreground task repeatedly logged its SQLite polling query.
The user interrupted the VM after about 24 seconds, while Anthropic was still processing
server-side research. The process exit left the Oban job in `executing`, the invocation in
`researching`, and its budget entry in `sent` without a response envelope.

## Goals

- Keep structured operational logs separate from interactive progress.
- Prevent stored thread, prompt, response, credential, and reply content from appearing in logs.
- Make a dry run visibly progress through durable stages without inventing a percentage.
- Recover work abandoned by graceful shutdown, VM termination, or process crashes.
- Never automatically repeat an Anthropic request that may already have been processed and billed.
- Apply the same interruption policy to dry-run and public workflows.
- Target approximately $0.05 or less for an ordinary invocation while preserving configurable
  higher limits for exceptional questions.
- Preserve complete bounded provider response envelopes in SQLite when a response is received.

## Non-goals

- A web UI, audit page, or new public API.
- Live visibility into Anthropic's internal server-tool passes. The non-streaming Messages API does
  not expose them while the request is in progress.
- A guaranteed per-request dollar cap. Anthropic does not provide a mid-request cost cutoff for a
  non-streaming request with server tools.
- Automatic retry of an ambiguous paid request.
- Log rotation or shipping. The process chooses stderr or a file; the host manages retention.
- Replacing SQLite, Oban, or the existing workflow stages.

## Output architecture

### Structured logs

`ContextBot.Logging` configures application-wide JSON Lines logging before application children
start. Every line is one JSON object containing a timestamp, severity, message/event name, and
allowlisted scalar metadata. Existing application-owned operational events remain compatible with
this output.

The `CONTEXT_BOT_LOG_PATH` environment variable controls the destination:

- Unset or empty: write to stderr.
- Absolute file path: open in append mode and write all Logger output there.
- Relative path, directory, or an unwritable path: fail startup with a safe error that contains no
  secret values.

The destination applies to dry-run tasks, local Phoenix operation, releases, and the deployed bot.
File rotation is external to the application.

Repository query logging is disabled by default. The current Ecto DEBUG output includes bound
parameters and therefore exposed invocation text and `raw_notification`. Application-owned events
provide safe IDs, stage, timing, queue, usage counts, estimated cost, and finite failure categories
without logging:

- `raw_notification` or `raw_thread`
- canonical prompts or Anthropic messages
- provider response bodies
- selected reply content
- credentials, authorization headers, or Bitwarden values

### Dry-run progress

`ContextBot.DryRun.Progress` is the only component that renders human-facing progress. It writes to
stdout, while Logger uses the configured structured-log destination.

For a TTY, progress is an indeterminate spinner with:

- the durable invocation ID;
- a human-readable stage;
- elapsed wall-clock time;
- a note that Claude research may take up to the configured HTTP timeout.

The renderer updates its animation without producing scrollback and redraws only when the stage or
elapsed-time display changes. It clears the active line before printing the final answer, usage,
cost, deferral, or failure.

For non-TTY stdout, the renderer emits a plain line once for each stage transition and no ANSI
control sequences. This keeps redirected output and CI logs stable. The final summary retains the
existing machine-readable `key=value` fields.

The stage display is based only on persisted invocation state:

1. `capturing_thread` — fetching the selected post and ancestors.
2. `thread_ready` — the snapshot is durable and queued for research.
3. `researching` — waiting for Claude; internal search/fetch progress is not observable.
4. `deferred_budget`, `complete`, or `failed` — terminal foreground result.

`ContextBot.DryRun.await/2` reports state changes through an optional callback while preserving its
existing return contract. Tests may inject the clock, sleep function, callback, and TTY decision.

## Interruption and recovery model

### Core rule

Recovery distinguishes work that is safe to repeat from provider exposure that is ambiguous. A
request is exposed once its budget entry is durably marked `sent`. If no response envelope was
committed afterward, the system cannot know whether Anthropic processed or billed it. That attempt
becomes `indeterminate`, and the invocation fails terminally with safe reason
`interrupted_after_send`. It is never retried automatically.

This replaces the current behavior that can retry an exposed timeout or transport failure.

### Recovery matrix

| Persisted condition | Recovery action |
|---|---|
| Eligibility or thread job abandoned | Return the job to its correct queue and resume. |
| Research has no budget entry | Clear a stale claim, return to `thread_ready`, and enqueue research. |
| Latest research budget entry is `reserved` | Reuse the reservation, clear the stale claim, and enqueue research. |
| Entry is `sent` with no response envelope | Mark it `indeterminate`, terminalize the invocation as `provider_response/interrupted_after_send`, and discard the orphan job. |
| Response envelope is committed | Resume processing the stored envelope without another provider request. |
| Deterministic reply publication is abandoned | Requeue publication; GET and exact-record reconciliation make it safe. |
| Invocation is deferred | Leave it for normal due-time admission. |
| Invocation is terminal | Do nothing. |

Dry-run work always returns to `dry_thread` or `dry_research`; public work returns to its public
queue. Recovery cannot create a reply job for a dry-run invocation.

### Startup recovery

`ContextBot.Workflow.Recovery` runs after the Repo starts and before any Oban queue starts. At that
point every job persisted as `executing` belongs to an earlier process and is orphaned. Recovery
classifies and updates the job, invocation, claim, and budget entry in bounded immediate SQLite
transactions before consumers may claim work.

The dry-run runtime invokes the same recovery entry point before starting its two dedicated queues.
The normal application places a one-shot startup recovery child before Oban in the supervision
order. Recovery is idempotent: rerunning it after partial startup produces the same finite state and
does not enqueue duplicate incomplete jobs.

### Runtime recovery

The maintenance worker continues scanning nonterminal invocations. It no longer treats every
`executing` job as active forever. It leaves fresh stage leases untouched and applies the same
recovery matrix after the stage-specific lease expires. Thread/identity work uses bounded HTTP
timeouts plus grace; research and publication use their existing durable claim leases.

The generic Oban Lifeline plugin is not enabled. It would blindly make orphaned jobs available and
could repeat an exposed Anthropic request.

### Process shutdown

SIGINT and SIGTERM stop new queue dispatch and request normal OTP shutdown. Oban receives its
configured shutdown grace period. If a worker completes within that window, its normal handoff is
preserved. If it is killed while still executing, startup recovery applies the matrix above.
SIGKILL and host loss cannot run cleanup, but they are handled on the next startup in the same way.

The dry-run command clears its spinner during normal exits and prints the invocation ID before work
starts, so an operator can inspect the durable row after an interruption.

## Research cost controls

The observed request used 53,085 input tokens and 1,330 output tokens across three Anthropic
server-tool passes with one request ID. At Sonnet 5's introductory August 2026 rates, token charges
alone are approximately $0.119. The large context came from direct, fully included search/fetch
results rather than the roughly 2 KB initial Context Bot request.

Ordinary defaults change to:

| Setting | Current | New default |
|---|---:|---:|
| Adaptive-thinking effort | `high` hard-coded | `medium`, validated by `ANTHROPIC_EFFORT` |
| Research output tokens | 8,192 | 4,096 |
| Web searches | 5 | 2 |
| Web fetches | 5 | 2 |
| Fetched content tokens | 50,000 | 10,000 |
| Tool continuations | 3 | 1 |
| Web search caller | direct | provider default dynamic filtering |
| Search/fetch response inclusion | full | excluded after code execution consumes it |
| Web fetch cache | bypassed | provider cache enabled |

The tool versions remain `web_search_20260318` and `web_fetch_20260318`. These versions support
dynamic filtering and excluded response inclusion. Removing `allowed_callers: ["direct"]` allows
Anthropic's default code-execution filtering to retain only relevant results. Omitting
`use_cache: false` restores the provider default cache behavior.

The system prompt continues to prefer primary sources, but it also instructs Claude to use the
smallest research sufficient for a defensible 300-character answer. Operators may raise the
validated environment limits for exceptional work.

The approximately $0.05 target is an expected ordinary cost, not a hard ceiling. The existing $5
research budget reservation remains because it covers fail-closed theoretical exposure to the 1M
context window; it is not a charge. Lowering it without a provider-enforced request cap could let
actual usage exceed the daily budget. Settled entries continue to use exact response usage and the
versioned integer pricing calculator. Web-search charges remain included.

Official behavior used by this design:

- Sonnet 5 introductory pricing through August 31, 2026:
  <https://platform.claude.com/docs/en/about-claude/models/whats-new-sonnet-5>
- Dynamic search filtering, per-search charges, and repeated server-tool passes:
  <https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool>
- Fetch caching, content limits, and response exclusion:
  <https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-fetch-tool>

## Configuration

New environment variables:

- `CONTEXT_BOT_LOG_PATH`: optional absolute append-only JSONL file path; defaults to stderr.
- `ANTHROPIC_EFFORT`: `low`, `medium`, or `high`; defaults to `medium`.

Existing environment defaults change as listed above in `.env.example` and `fly.toml`. README
operations documentation explains output streams, file logging, expected research latency, cost
tradeoffs, and interruption outcomes.

Configuration remains validated once at startup. Invalid paths, effort values, or bounds fail
closed before external work begins.

## Testing and acceptance

### Logging

- Default output is JSONL on stderr.
- An absolute `CONTEXT_BOT_LOG_PATH` appends valid JSON lines and keeps stdout free.
- Invalid file destinations fail startup without exposing secret values.
- Query parameters, thread text, prompts, responses, API keys, and reply text never appear.

### Progress

- TTY output animates one spinner line and clears it before the final result.
- Non-TTY output contains one plain line per durable stage and no control sequences.
- The display uses injected time and terminal capabilities in deterministic tests.
- A long research request visibly remains `researching` with elapsed time.

### Recovery

- Every recovery-matrix row has a behavior-first database test.
- Startup recovery completes before actual Oban queue producers begin dispatching.
- A sent/no-envelope attempt becomes one indeterminate budget entry and one terminal invocation,
  with no new provider job.
- Reserved work and stored responses resume without duplicate reservations or requests.
- Dry work never enters public queues or publication.
- Repeated recovery passes are idempotent.
- SIGTERM integration coverage verifies clean shutdown; orphan fixtures verify hard-loss recovery.

### Cost controls

- Request-shape tests prove medium effort, dynamic filtering, response exclusion, provider fetch
  cache, and the new limits.
- Settings tests cover defaults, overrides, and invalid values.
- Pricing tests retain exact cache/search/output arithmetic.
- The complete dry-run workflow uses fake public and Anthropic providers; verification performs no
  paid request and makes no Bluesky publication.

### Completion gate

- `direnv exec . just check`
- `direnv exec . just docker-build`
- Production-image `/health` smoke test with `BOT_ENABLED=false`
- Independent code review focused on ambiguous-provider recovery and log redaction

