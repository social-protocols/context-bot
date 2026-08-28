# Anthropic cost and interruption recovery

**Date:** 2026-08-10  
**Updated:** 2026-08-28  
**TL;DR:** Server-side research may bill far more input than the visible prompt or answer suggests.
Bound ordinary research aggressively. Drain deploys so in-flight Anthropic HTTP can finish. If a
sent attempt has no envelope, wait out `ANTHROPIC_HTTP_TIMEOUT_MS` and then start a **new** budget
attempt — do not terminalize the mention forever, and do not invent Messages API idempotency.

## Context

The first real read-only dry run appeared to hang because the foreground process printed every Ecto
poll at debug level while no Oban consumer was running. After that was corrected, the Anthropic
console showed three HTTP segments for one researched response with 53,085 aggregate input tokens
and 1,330 output tokens, costing about $0.11. The visible question and Bluesky ancestor chain were
far smaller, so we investigated both ordinary request cost and safe behavior when a local process is
interrupted during a paid provider call.

A later Fly deploy of PR #54 sent SIGINT during a 300s Anthropic HTTP call for invocation 6. Startup
recovery terminalized that mention as `interrupted_after_send` with a sent $5 reservation and no
envelope. The mention could not finish. Anthropic does not document request idempotency for
`POST /v1/messages`, and the Message Batches API is too slow for a live Bluesky reply.

## Investigation

The three Anthropic rows were tool-use continuations of one logical research attempt. Server-side
web search/fetch material and the growing message prefix can contribute input billing even when tool
results use `response_inclusion: "excluded"`; exclusion reduces returned/stored content, not the
provider's research work. Prompt caching can reduce repeated-prefix input charges after a prefix is
cacheable, but it is an optimization and does not make an initial search/fetch free.

The workflow already persisted a budget reservation before network I/O, marked it `sent` immediately
before POST, and stored every complete HTTP response in `anthropic_response_envelopes`. Process death
after POST but before the envelope transaction used to fail the invocation forever. Retrying that
same attempt could issue a second paid request if Anthropic completed the first one; waiting until
the HTTP timeout elapses, then starting a **new** reservation, is the accepted crash-path cost.

## Findings

- Ordinary defaults are medium effort, 4,096 output tokens, five searches, two fetches, 10,000 fetched
  content tokens, and one tool continuation. The request asks for only enough research to support a
  defensible 300-character answer.
- Tool responses are excluded from the returned Anthropic payload, but can still affect provider
  input usage and cost. The settled budget ledger is the authoritative cost record.
- Fly's kill_signal default is SIGINT and kill_timeout max is 300s. The release traps INT/TERM,
  forwards SIGTERM, and sets `kill_signal = "SIGTERM"` with `kill_timeout = 300`. Oban's
  `shutdown_grace_period` matches that cap so a deploy can drain in-flight research/reply.
- A `sent` or `indeterminate` budget entry without an envelope is **not** terminal. While
  `now < sent_at + ANTHROPIC_HTTP_TIMEOUT_MS`, recovery keeps the invocation researching and does
  not POST. After the window, the old row stays indeterminate and a new attempt may be reserved.
- Failed `provider_response/interrupted_after_send` is reopened with the same matrix, including
  operator `just reprocess` / `just fly-reprocess` after the timeout. Replayable retained envelopes
  still reprocess locally with no new POST, except `code_execution_failed`, which starts a **new**
  paid attempt. Automatic recover_failed does not reopen deterministic parser hard-fails.
- Permanent non-replayable failures (eligibility, unauthorized/session, publication_conflict when a
  `reply_uri` already exists, user/policy skips) are not auto-retried. A set `reply_uri` never
  allocates a second post.
- Deterministic abandoned work is recovered before Oban consumers start. Runtime maintenance uses
  the same coordinator and exact lease boundaries.
- The foreground dry-run command traps SIGINT/SIGTERM, stops its await task, pauses and gracefully
  stops only the standalone dry queues, and leaves durable classification to startup recovery.

## Implications

When changing Anthropic tools or models, review both tool limits and the reservation amount; visible
answer length is not a useful upper bound on cost. Preserve the response-envelope transaction. Do
not add Messages `Idempotency-Key` behavior that Anthropic does not document, and do not switch
research to the Message Batches API. New workflow stages must be added to the centralized recovery
matrix with dry and public queue tests before they can be dispatched. Operators should retain the
printed `dry_run_id` after interruption and inspect only safe workflow/budget metadata.
