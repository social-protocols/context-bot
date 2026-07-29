# POC Provider Contracts

**Date:** 2026-07-29
**TL;DR:** The live POC needs overlapping newest-first notification drains, opaque Anthropic conversation preservation, exposure-aware budget attempts, and deterministic PDS write reconciliation. Current Req uses nested named-Finch options, and Oban's SQLite engine is `Oban.Engines.Lite`.

## Context

The approved Context Bot POC design needed an implementation-level check against current ATProto, Anthropic, Req, Finch, and Oban contracts before its build plan could be made concrete. The investigation focused on details that could cause missed mentions, duplicate replies, broken prompt caching, incomplete audit data, or budget undercounting.

## Findings

### ATProto ingestion and threads

- `app.bsky.notification.listNotifications` must explicitly send `reasons=mention` and `priority=false`; otherwise the account's stored priority-notification preference can filter ordinary mentions.
- Filtered pages may contain fewer than the requested limit, including zero notifications, while still returning a cursor. A drain must follow the opaque cursor until it is absent, a durable `(URI, CID)` watermark is reached, or the configured page cap is reached.
- Each poll starts again at the newest page. Persisting the backward cursor as the next poll position would miss newly arriving notifications.
- `app.bsky.feed.getPostThread` needs `depth=0` to suppress descendants. Ancestors are nested through the `parent` union; the requested post is the top-level `thread` value, not necessarily the conversation root.

Primary contracts: [notification Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/notification/listNotifications.json), [thread Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/getPostThread.json).

### ATProto session and publication

- One supervised process should own access/refresh JWTs in memory and serialize refresh. On an access-token 401, refresh once and retry; reject a session whose returned DID differs from the configured bot DID.
- A reply rkey must be a valid 13-character TID allocated and persisted once. Do not reuse the source post rkey.
- Freeze `text`, `createdAt`, `reply.root`, and `reply.parent` before the first write. GET the deterministic URI before PUT; use `swapRecord: null` for create-only behavior on the Bluesky PDS; after timeout or `InvalidSwap`, GET and accept only an exactly matching record.

Primary contracts: [TID specification](https://atproto.com/specs/tid), [putRecord Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/repo/putRecord.json), [getRecord Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/repo/getRecord.json).

### Anthropic Messages

- The direct Messages request uses `anthropic-version: 2023-06-01`, top-level automatic `cache_control`, Sonnet 5 adaptive thinking, and dated `web_search_20260318`/`web_fetch_20260318` server tools. Sonnet 5 should not receive non-default sampling settings.
- A `pause_turn` continuation appends the entire assistant content unchanged, including unknown blocks, signatures, encrypted fields, caller metadata, and unresolved server-tool calls. The model, system, tools, and other cache-affecting settings remain identical.
- The one optional repair appends the complete successful assistant response and a final user instruction. Tools and the prior prompt remain byte-equivalent; a cache miss is permitted.
- Every raw HTTP response must be stored before decoding or deciding to continue, retry, repair, or publish.
- A hard budget also needs a durable `sent` marker before handing a POST to Finch. Recovery treats a sent attempt without a recorded response as indeterminate and allocates a new reservation before replay; otherwise a crash could cause a second billable POST under one reservation.

Primary contracts: [server tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools), [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [API errors](https://platform.claude.com/docs/en/api/errors).

### Elixir infrastructure

- Current compatible dependencies are Req `~> 0.7.1`, Finch `~> 0.23.0`, Oban `~> 2.23.0`, and ecto_sqlite3 `~> 0.24.1`.
- Req 0.7 configures a named Finch and timeouts under `finch: [name: ..., pool_timeout: ..., receive_timeout: ..., request_timeout: ...]`; the older top-level timeout form is deprecated.
- Oban's supported SQLite engine is `Oban.Engines.Lite`; use `testing: :manual` with `Oban.Testing` in database tests.
- Use `Repo.transaction(..., mode: :immediate)` only for short claim/reservation transactions, never around network calls.

Primary contracts: [Req package](https://hex.pm/packages/req), [Req Finch integration](https://github.com/wojtekmach/req/blob/main/lib/req/finch.ex), [Oban SQLite installation](https://oban.hexdocs.pm/installation.html#sqlite3).

## Implications

The POC plan must test empty notification pages with cursors, newest-first overlap, descendant exclusion, opaque continuation equality, response-before-decision persistence, pre-send budget exposure, resumable in-progress worker states, and deterministic GET/PUT reconciliation. Provider clients should disable automatic retry so the durable workflow owns attempt keys, cost reservations, and retry classification.
