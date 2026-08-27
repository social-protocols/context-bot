# Fail-closed recoverable recovery matrix

**Date:** 2026-08-27
**TL;DR:** Public freeze must not omit a full-response link when `full_response` exists.
Document-create failure is `failed/provider_response` with the envelope retained.
Reprocess of a published `reply_uri` refuses rather than allocating a second Bluesky TID.

## Product rules

1. Fail closed on anything that would degrade answer quality. Do not publish a compact
   reply from incomplete research or a missing Standard.site reader URL.
2. Every failure stays retryable or recoverable. Idempotent retries: no second Bluesky
   post at a new TID; no second Anthropic POST when a response envelope exists.
3. Integrity: keep `full_response` on fail/repair; log ATProto/Standard.site errors.
4. Robustness: drain in-flight work on SIGTERM; do not mark a sent Anthropic attempt
   retryable until the HTTP timeout has elapsed.

## Recovery matrix

| Stage | Fail-closed means | Durable state | Idempotent retry |
|---|---|---|---|
| Poll | Do not invent receipts from a bad page. Log the ATProto error and keep the current drain. | No new invocation. Cursor is ephemeral. | Next poll starts newest-first. ExpiredToken is unauthorized and refreshes once. |
| Eligibility | Skip unless `bsky.team` bidirectional, Skywatch elder, or exact allowlisted DID. | `ineligible` or deferred rate/capacity. | Deferred work is reconsidered oldest-first. Ineligible stays terminal by product rule. |
| Thread | Ancestors only (`depth=0`). Invalid/missing thread is `thread_unavailable`. | Canonical snapshot or failed. | Retry fetch; never fetch descendants. |
| Research send | Reserve, mark sent, then POST. No Messages Idempotency-Key. | Budget row `sent` with `sent_at`. | While HTTP timeout remains, snooze/wait. After timeout, mark indeterminate and start a **new** reservation. Never replay a sent attempt without its envelope. |
| Envelope persist | Commit the exact HTTP envelope before decode/price/select. | `ResponseEnvelope` + `response_recorded_at`. | Replay the envelope. No second POST. |
| Parse / tools | Unknown `server_tool_use` → `:unexpected_tool_use`. Native `web_search`/`web_fetch` plus code-execution subtools are allowlisted. Non-zero `return_code` / tool-result error → `:code_execution_failed`. Truncation/refusal/max_tokens fail closed. | Failed `provider_response`; envelope kept. | Operator or startup recovery reopens to `thread_ready` and replays the envelope. |
| Document create | If `full_response` is present, Standard.site publication+document must succeed. Do not freeze or PUT a compact reply that would omit the reader URL. | Failed `provider_response` with `standard_site_document_failed`, `full_response` retained, no `reply_rkey`. | Reprocess/recovery replays the envelope and retries create. No Bluesky post exists yet. |
| Freeze | Freeze one repo/rkey/record **after** a reader URL when the writeup exists. Dry-run never freezes. | `reply_ready` with frozen intent + document URI. | Same rkey on later publication attempts. |
| Bluesky PUT | Create-only at the frozen rkey. GET before PUT; reconcile after. If `full_response` exists and the frozen record has no reader URL, do not PUT. If GET already matches that unlinked record, record `reply_uri` instead of allocating a new TID. | `complete` with `reply_uri`, or failed `missing_reader_url` without a write. | Same rkey. Reprocess of `reply_uri` is `:already_published`. |
| Startup | Drain SIGTERM (#55). Recover orphans oldest-first. Log `recovery_failed` instead of swallowing. | Claims cleared; jobs made available or scheduled until the HTTP timeout. | Envelope → replay. Sent-without-envelope inside timeout → wait. After timeout → new attempt. |

## Verified already on origin/main

- **#55** `interrupted_after_send` waits out `anthropic_http_timeout_ms`, then a new reservation. ResearchWorker snoozes `:wait`.
- **#56** `return_code != 0` and documented `*_tool_result_error` are `:code_execution_failed`.
- **#51** length repair/split keeps `full_response` via `Reply.full_response_from_messages/1`.
- **#50** ATProto HTTP 400 `ExpiredToken`/`InvalidToken` is `:unauthorized`, not a permanent 400.
- **#57** `site.standard.*` putRecord uses `validate: false`. Create can succeed; this audit still fails closed if it does not.

## Highest-leverage fixes in this change

- ResearchWorker no longer queues ReplyWorker after a Standard.site create failure.
- Reprocessor refuses `reply_uri` (`:already_published`) instead of clearing it and minting a new TID.
- ReplyWorker refuses to PUT an unlinked compact post when `full_response` exists.
- Poller, Recovery, and Runner transport errors are logged with allowlisted fields.

## Left unchanged (with why)

- Compact-only publish when research produced no `full_response` (existing dual-format-optional path).
- `Document.add_post_ref/4` is unused; not wired.
- ReplyWorker part2 GET failures still classify as conflict (bounded, no second rkey).
- Health aggregate rescue still returns empty counts (health must not crash).
- Facet update-in-place on an already-published unlinked post is refused, not overwritten. ReplyWorker remains create-only except exact GET match.
- Invalid DID `{:permanent, 400}` in `resolve_did/1` is local validation, not an HTTP swallow.
- No Anthropic Messages Idempotency-Key (undocumented). No undeclared tools.
