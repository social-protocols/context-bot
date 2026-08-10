# Anthropic cost and interruption recovery

**Date:** 2026-08-10  
**TL;DR:** Server-side research may bill far more input than the visible prompt or answer suggests.
Bound ordinary research aggressively, and never replay an HTTP attempt that may already have reached
Anthropic unless its complete response envelope was committed locally.

## Context

The first real read-only dry run appeared to hang because the foreground process printed every Ecto
poll at debug level while no Oban consumer was running. After that was corrected, the Anthropic
console showed three HTTP segments for one researched response with 53,085 aggregate input tokens
and 1,330 output tokens, costing about $0.11. The visible question and Bluesky ancestor chain were
far smaller, so we investigated both ordinary request cost and safe behavior when a local process is
interrupted during a paid provider call.

## Investigation

The three Anthropic rows were tool-use continuations of one logical research attempt. Server-side
web search/fetch material and the growing message prefix can contribute input billing even when tool
results use `response_inclusion: "excluded"`; exclusion reduces returned/stored content, not the
provider's research work. Prompt caching can reduce repeated-prefix input charges after a prefix is
cacheable, but it is an optimization and does not make an initial search/fetch free.

The workflow already persisted a budget reservation before network I/O, marked it `sent` immediately
before POST, and stored every complete HTTP response in `anthropic_response_envelopes`. The unsafe
case was process death after POST but before the response envelope transaction. Retrying that row
could issue a second paid request even if Anthropic completed the first one.

Recovery was exercised with real SQLite invocation, budget, response-envelope, and Oban rows. Exact
leases are 21,600,000 ms for research and 300,000 ms for publication; identity and thread work use
their configured HTTP timeout plus 30 seconds. Public and dry invocations were tested on separate
queues, including repeated recovery passes and process interruption.

## Findings

- Ordinary defaults are medium effort, 4,096 output tokens, two searches, two fetches, 10,000 fetched
  content tokens, and one tool continuation. The request asks for only enough research to support a
  defensible 300-character answer.
- Tool responses are excluded from the returned Anthropic payload, but can still affect provider
  input usage and cost. The settled budget ledger is the authoritative cost record.
- A `sent` or `indeterminate` budget entry is resumable only when its actual durable
  `ResponseEnvelope` exists. A timestamp alone is insufficient.
- Sent-without-envelope is terminalized as `provider_response/interrupted_after_send`, with the
  reservation retained as indeterminate. No automatic provider retry is created.
- Deterministic abandoned work is recovered before Oban consumers start. Runtime maintenance uses
  the same coordinator and exact lease boundaries.
- The foreground dry-run command traps SIGINT/SIGTERM, stops its await task, pauses and gracefully
  stops only the standalone dry queues, and leaves durable classification to startup recovery.

## Implications

When changing Anthropic tools or models, review both tool limits and the reservation amount; visible
answer length is not a useful upper bound on cost. Preserve the response-envelope transaction and
the no-replay rule. New workflow stages must be added to the centralized recovery matrix with dry
and public queue tests before they can be dispatched. Operators should retain the printed
`dry_run_id` after interruption and inspect only safe workflow/budget metadata.
