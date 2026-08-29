# Published prompt template and Messages API parameters

**Date:** 2026-08-29
**TL;DR:** The live reader is Standard.site, not the deferred `org.social-protocols.contextbot.*`
audit DAG. A full response is published only after a hashed prompt document exists, and the
full-response markdown must link that document plus the allowlisted request parameters.

## Why

Issue #63 asks for input transparency from the published full response: the prompt template and
the Anthropic Messages parameters that were actually sent. That was already in the 2026-07-27
design (`prompt` + `modelInvocation` records and an audit viewer). The POC never shipped those
lexicons. Homepage copy still claimed the full prompt lived in ATProto records.

## What is public

1. A stable `site.standard.document` whose rkey is derived from `CONTEXT_BOT_SYSTEM_V5` plus a
   SHA-256 prefix. `textContent` is the exact system-prompt bytes. The markdown also includes the
   `LENGTH_REPAIR` user-turn text and its hash.
2. The full-response document links that prompt URL and prints semantic version, SHA-256, the
   allowlisted Messages fields (`anthropic-version`, `model`, `max_tokens`, `effort`, `thinking`,
   `tool_choice`, tool types/`allowed_callers`/`max_uses`/`max_content_tokens`/`response_inclusion`,
   `cache_control`, continuation/length-repair flags), and the first user message.
3. Credentials, authorization headers, cookies, non-CDN image URLs, and assistant thinking blocks
   are omitted. The page states that hidden reasoning is unavailable and that replay is not
   deterministic.

## Fail-closed

If `full_response` exists, publication, prompt-document ensure, and full-response create must all
succeed before reply freeze. A missing prompt reader URL is `:prompt_inputs_missing` and does not
put a full-response record. A stored prompt document whose `textContent` does not match the current
system prompt is `:prompt_document_conflict`.

## Not shipped

`org.social-protocols.contextbot.prompt`, `modelInvocation`, thread-snapshot records, IPFS, and a
Phoenix audit viewer remain out of scope.
