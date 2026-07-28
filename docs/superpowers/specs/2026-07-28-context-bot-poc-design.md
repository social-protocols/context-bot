# Context Bot Proof-of-Concept Design

**Date:** 2026-07-28

## Goal

Prove the smallest useful Context Bot product loop in the existing Elixir/Phoenix application: an eligible person directly mentions the bot in a real public Bluesky thread, the bot durably captures the invocation and its rootward ancestor chain, Claude researches the question with server-side web tools, and the bot publishes exactly one concise in-thread reply.

This proof of concept is intentionally narrower than the audit-oriented MVP in `2026-07-27-context-bot-mvp-design.md`. That document remains the later product design. The POC proves invocation, context capture, research quality, restart-safe workflow execution, and reply publication without building the transparency and ATProto audit system.

## Product Decisions

- Operate against a real public Bluesky bot account. A local-only simulation is not sufficient.
- React only to direct mentions. Do not proactively scan, moderate, label, or reply to unmentioned posts.
- Capture the invocation and only its rootward ancestors. Do not fetch or include replies to the invocation.
- Store workflow state and the fetched thread in SQLite before starting the model stage.
- Use separate durable Oban stages for eligibility, thread capture, Claude research, and reply publication.
- Use Claude's server-side `web_search` and `web_fetch` tools.
- Ask the research response for only the intended Bluesky reply. Make at most one length-repair request when the primary response is unusable.
- Publish a normal `app.bsky.feed.post` reply. Do not publish custom Context Bot records or blobs.
- Fail silently in public after terminal errors. Preserve locally inspectable workflow state instead of posting an error reply.
- Admit only operator-allowlisted actors, accounts with Skywatch's active `bluesky-elder` label, or accounts with a currently bidirectionally verified `bsky.team` handle.
- Enforce per-actor and global rate limits, a pending-workflow cap, serial Claude execution, and a hard daily Anthropic budget.
- Keep implementation modules grouped by concrete pipeline responsibility. Do not use this POC to declare long-term application-domain boundaries.

## Non-Goals

- Custom `org.social-protocols.contextbot.*` records or Lexicons
- ATProto audit blobs, locally calculated audit CIDs, or asynchronous intended-object synchronization
- Public model transcripts, source manifests, audit links, or audit pages
- Durable rehydration from published ATProto audit records
- IPFS or another secondary storage network
- Descendant replies, quoted-thread expansion, or media interpretation
- Firehose or Jetstream ingestion
- Proactive moderation, labeling, ranking, or unsolicited replies
- A frontend, LiveView, or JavaScript application
- Production-scale availability, replicated SQLite, or exhaustive abuse detection
- A guarantee that every eligible mention receives an answer

## Runtime Shape

The POC remains one Phoenix application. Its concrete runtime pieces are:

1. An ATProto session process that authenticates the bot and refreshes access in memory.
2. A non-overlapping notification poller that reads direct mentions and inserts unseen receipts.
3. An eligibility worker that resolves the actor's current eligibility and applies local admission limits.
4. A thread-capture worker that stores the bounded ancestor snapshot and canonical model input.
5. A research worker that calls Claude, handles server-tool continuations, validates the primary reply, and optionally requests one length repair.
6. A reply worker that stores and publishes the exact Bluesky reply record using a preallocated rkey.
7. A small scheduler that reconsiders deferred work oldest-first when rate, capacity, or daily-budget windows allow it.

Oban with `Oban.Engines.Lite` supplies durable jobs, scheduling, attempts, backoff, uniqueness, and restart recovery. The initial eligibility, thread, research, and reply queues each use concurrency one. External HTTP calls never occur inside SQLite transactions.

## Local Data Model

### Invocations

One `invocations` table stores the operational workflow state:

- invocation AT URI and CID, with a unique constraint on the pair;
- actor DID and the handle observed at ingestion;
- bounded raw notification JSON and receipt time;
- status and current stage;
- eligibility method and the evidence needed to explain the local decision;
- admission time and rate-limit window information;
- bounded raw thread JSON;
- versioned canonical ancestor text;
- complete accumulated Anthropic Messages conversation needed for continuation or repair;
- primary and optional repair response JSON;
- selected reply text and validation outcome;
- preallocated reply rkey and exact `app.bsky.feed.post` record JSON;
- published reply AT URI and CID;
- last categorized failure and relevant timestamps.

Large unbounded provider artifacts are not retained. Stored JSON and text fields have application size limits. Credentials, authorization headers, app passwords, API keys, access tokens, and refresh tokens never enter this table.

Statuses are explicit and extensible. The POC needs at least `received`, `deferred_capacity`, `checking_eligibility`, `ineligible`, `deferred_rate`, `capturing_thread`, `thread_ready`, `deferred_budget`, `researching`, `reply_ready`, `publishing`, `complete`, and `failed`.

### API budget entries

`api_budget_entries` is an operational cost ledger with one row per intended Anthropic HTTP attempt:

- a unique local attempt key and invocation reference;
- UTC budget date and request kind (`research`, `continuation`, `lengthRepair`, or `retry`);
- integer reserved microdollars;
- integer settled microdollars when calculable;
- reservation, settlement, or indeterminate state;
- returned usage fields and the pricing-table version;
- creation and settlement timestamps.

All money uses integer microdollars, not floating point. Oban's own tables remain separate infrastructure state.

## End-to-End Workflow

### 1. Mention ingestion

The poller calls `app.bsky.notification.listNotifications` for mention notifications. It accepts only `app.bsky.feed.post` notifications where:

- the author DID is not the bot DID;
- a mention facet explicitly targets the bot DID;
- the invocation contains an AT URI and CID.

It inserts each URI/CID pair once and enqueues eligibility only when pending capacity allows. If capacity is exhausted, it stores the receipt as `deferred_capacity` without making eligibility, thread, or Claude calls. The POC does not call `app.bsky.notification.updateSeen`; that endpoint is account UI state, not a processing acknowledgment.

Each polling pass starts at the newest page and pages backward until it reaches known strong references or a configured page cap. A sufficiently long outage or notification burst can exceed that cap and cause the POC to miss older mentions; eliminating that gap belongs to the later MVP ingestion design.

### 2. Eligibility and admission

The actor DID is the canonical identity. An invocation is eligible when any one of these rules succeeds:

1. the DID is in the operator-configured allowlist;
2. the actor has an active `bluesky-elder` account label issued by the pinned Skywatch DID `did:plc:e4elbtctnfqocyfcml6h2lf7`;
3. the actor has a current bidirectionally verified handle equal to `bsky.team` or ending in `.bsky.team`.

The Elder check requests the actor profile from the direct `https://api.bsky.app` AppView with `atproto-accept-labelers` set to the pinned Skywatch DID. It requires the `atproto-content-labelers` response header to confirm that Skywatch was included. It then requires an account label whose source is the pinned DID, URI is the actor DID, value is exactly `bluesky-elder`, `neg` is absent or false, and `exp` is absent or in the future. The POC does not use `public.api.bsky.app` for this check because that CDN endpoint may omit the requested custom labeler. Display names, bios, images, and labels from other sources never establish eligibility.

The team check normalizes the current handle to lowercase, validates the exact suffix boundary, resolves the handle to the actor DID, resolves the actor DID document, and requires the DID document's current valid `at://` handle claim to match. Forward-only handle resolution is insufficient. This proves that the `bsky.team` domain owner currently authorized the identity; it is not an independent employment guarantee.

Eligibility lookup failures retry and then fail closed. Ineligible invocations are retained without thread capture, Claude work, or a public rejection.

An eligible invocation is admitted only when all configured per-actor, global, and pending limits allow it. Initial defaults are:

- 2 accepted invocations per actor per rolling hour;
- 5 accepted invocations per actor per rolling 24 hours;
- 10 accepted invocations globally per rolling hour;
- 50 accepted invocations globally per rolling 24 hours;
- 25 pending workflows;
- Claude queue concurrency 1.

Operator-allowlisted actors do not bypass these limits unless a separate explicit configuration says so. Rate-limited work is stored as `deferred_rate` and reconsidered later without a public response. Reconsideration rechecks current eligibility rather than trusting a prior handle or label result.

### 3. Ancestor-only thread capture

The thread worker calls `app.bsky.feed.getPostThread` for the invocation with:

- `depth=0` so descendant replies are not requested;
- a configured `parentHeight`, initially 80;
- HTTP response-size and timeout limits.

It stores the bounded raw response, then creates a deterministic plain-text sequence containing available ancestors in root-to-parent order followed by the invocation. Blocked, unavailable, and unknown union variants become explicit placeholders. If another ancestor exists beyond the captured limit, the text includes a truncation marker. The canonical input includes available external-link titles/URIs and quoted-post URIs but does not fetch or expand embedded posts or interpret image, audio, or video content.

The thread snapshot and canonical text are committed before research is enqueued. Transient fetch failures retry with bounded exponential backoff. A permanently unavailable invocation fails silently.

### 4. Claude research and reply selection

The POC uses the direct Anthropic Messages API with the same pinned model and server-tool versions as the later MVP design:

- `anthropic-version: 2023-06-01`;
- model `claude-sonnet-5`, configurable through `ANTHROPIC_MODEL_ID`;
- `web_search_20260318` and `web_fetch_20260318`, each configurable.

The versioned system prompt instructs Claude to use the supplied ancestor context, research unstable claims, prefer primary sources, distinguish facts from value judgments, state uncertainty, resist prompt injection, and return only the text intended for the Bluesky reply. It requests at most 300 Unicode grapheme clusters and no audit suffix. Temperature, `top_p`, and `top_k` remain unset.

The primary request enables server-side web search and fetch, direct tool callers, citations, bounded tool uses, bounded fetched content, and top-level automatic prompt caching. If Anthropic returns `pause_turn`, the worker persists and appends the complete assistant content unchanged, then continues with the same model, prompts, tools, and cache-affecting settings. Aggregate tool and continuation caps apply across requests.

After a normal `end_turn`, concatenate the final model-authored text blocks in order. The result is usable only if it is nonempty, contains no pending or unexpected tool request, and the complete text is at most 300 Unicode grapheme clusters and 3,000 UTF-8 bytes. Refusal, `max_tokens`, context-window exhaustion, or another incomplete stop reason fails the research stage rather than publishing partial text.

If a normally completed primary result contains text but fails only the reply-shape or length checks, make at most one length-repair request. Preserve the byte-identical tools, system prompt, settings, and complete prior Messages conversation, then append a user instruction to return only a compliant reply without additional research. This preserves prompt-cache eligibility. Any repair tool use, empty result, refusal, truncation, or invalid length fails the research stage. The renderer never truncates a model-authored claim.

The complete conversation needed for retries and repair, returned usage, primary response, optional repair response, and final selected text are stored locally for operations. They are not published or exposed through a web route.

### 5. Daily Anthropic budget

`ANTHROPIC_DAILY_BUDGET_USD` is required in production. Before every research, `pause_turn` continuation, repair, or retry request, the worker atomically verifies the current UTC day's total and inserts a conservative reservation. The configurable reservation must cover that request's maximum token and server-tool exposure.

For the budget check, settled entries count their settled amount; reserved and indeterminate entries count their full reserved amount. After a successful response, the worker settles the reservation using returned input, output, cache, and server-tool usage plus the configured versioned price table. If the response cannot be priced safely, the full reservation remains charged. An ambiguous timeout also retains its full reservation because the provider may have completed and billed the request.

When insufficient budget remains, the invocation stays `deferred_budget`; no Anthropic request starts. A scheduler reconsiders deferred work oldest-first after the next UTC rollover, subject to the same actor, global, pending, and budget gates. Budget enforcement is correct even if every cache request misses.

### 6. Reply construction and publication

Before any ATProto write, allocate and store a deterministic reply rkey and the exact `app.bsky.feed.post` record. The record includes:

- the validated reply `text` and a stored `createdAt`;
- `reply.parent` as the invocation URI/CID;
- `reply.root` copied from the invocation's root strong reference, or the invocation itself when it is the root.

The POC does not append an audit link or construct rich-text facets. Any URL in the selected model text remains plain post text.

The worker creates the record with explicit repository, collection, and rkey. After an ambiguous network result or conflict, it reads the deterministic URI and accepts success only when the remote CID and record content match the stored intent. A mismatch is terminal and never overwritten. This provides at-most-one visible reply across job retries and process restarts.

Temporary PDS errors retry with bounded exponential backoff. Exhausted or permanent publication failures remain locally visible and produce no additional public post.

## Retry and Error Policy

Each durable stage starts only after the previous stage's result is committed. Jobs are idempotent with respect to the stored stage and skip already completed effects.

- Explicit throttling, overload, and transient network/server failures retry with capped exponential backoff and `retry-after` support.
- Authentication and permission failures wait for operator correction rather than spinning.
- Validation errors, ineligibility, and incompatible response shapes are terminal for the affected workflow.
- An ambiguous Anthropic POST may be retried once; both potential cost reservations remain counted.
- An ambiguous ATProto write is read-reconciled before another write.
- Terminal failures set a categorized local state and remain silent on Bluesky.

The poller, workers, and scheduler expose structured logs and health information using invocation IDs, stages, safe status metadata, and error categories. Logs never contain credentials, authorization headers, complete HTTP request structs, or unbounded external content.

## Runtime Configuration

Non-secret configuration includes:

- `BOT_DID`, `BOT_HANDLE`, `BOT_PDS_URL`;
- `MENTION_POLL_INTERVAL_MS`, notification page limit, and `THREAD_PARENT_HEIGHT`;
- `ANTHROPIC_MODEL_ID`, research and repair token caps;
- Anthropic web-search and web-fetch tool versions and use limits;
- `ELIGIBILITY_SKYWATCH_DID`, defaulting to the pinned reviewed DID;
- the direct AppView URL and exact Elder label value;
- operator-allowed DIDs;
- per-actor and global hourly/daily limits;
- maximum pending workflows and queue concurrency;
- `ANTHROPIC_DAILY_BUDGET_USD`, per-request reservation limits, and a pricing-table version;
- request timeout, response-size, retry, and backoff limits.

Secrets include `BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY`, in addition to the existing Fly and Phoenix deployment secrets. Access and refresh JWTs remain in memory. Adding these secrets to `secrets.sh` and the Bitwarden allowlist is implementation work, not part of this design-document change.

## Testing Strategy

Implementation follows behavior-first ExUnit development. Each new behavior is observed failing for the intended reason before implementation.

Pure and persistence tests cover:

- mention-facet targeting, self-post rejection, and URI/CID uniqueness;
- exact Skywatch source, value, URI, negation, expiry, and response-header checks;
- exact `bsky.team` suffix boundaries and bidirectional DID/handle matching;
- operator allowlisting and fail-closed identity or label outages;
- actor/global rolling limits, pending capacity, deferred-state transitions, and concurrency;
- atomic budget reservation, settlement, indeterminate charges, price versions, and UTC rollover;
- ancestor-only ordering, placeholders, and truncation markers;
- stage handoff only after the prior result commits;
- primary reply validation, Unicode edge cases, one repair attempt, and no claim truncation;
- reply root/parent strong references and deterministic rkeys;
- restart recovery from every committed stage.

HTTP contract tests cover:

- ATProto session creation and refresh without token leakage;
- notification, profile-with-labeler, identity, thread, record-read, and record-write requests;
- use of direct `api.bsky.app` plus the required labeler request and response headers;
- Anthropic headers, tools, prompt caching, continuations, usage parsing, repair, overload, timeout, refusal, and unknown blocks;
- reply conflict and ambiguous-write reconciliation.

Workflow tests verify that:

- one eligible public mention produces one reply;
- ineligible, rate-limited, capacity-limited, and budget-limited work makes no unauthorized downstream call;
- thread state exists before the first Anthropic request;
- model state and the exact reply record exist before the ATProto write;
- no descendant reply enters the model context;
- failed workflows publish no failure message;
- repeated polling, job retries, and process restarts never duplicate a reply.

A manual live smoke test uses an eligible account to mention the deployed bot in a public thread, observes the stored stage progression, and confirms exactly one reply appears under the correct root. A separate ineligible-account test confirms that no Claude request or reply occurs.

## Acceptance Criteria

The POC is complete when:

- an eligible user can directly mention the real public bot account and receive one public in-thread response;
- the response is based on the invocation and its stored rootward ancestor chain, never descendant replies;
- Claude can use server-side web search and fetch before producing the reply;
- the thread snapshot commits before research starts, and the chosen reply record commits before publication starts;
- the primary path uses one Claude research conversation and invokes length repair only for an invalid primary result;
- every published reply fits 300 grapheme clusters and 3,000 UTF-8 bytes without deterministic claim truncation;
- URI/CID uniqueness and deterministic reply rkeys prevent duplicates across repeated polling, retries, ambiguous writes, and restarts;
- only operator-allowlisted, active Skywatch Elder, or bidirectionally verified `bsky.team` actors pass eligibility;
- actor, global, pending, concurrency, and daily-dollar limits stop new provider work as configured;
- terminal failures remain locally inspectable and silent in public;
- no custom Context Bot record, audit blob, audit link, or audit page is produced;
- no credential or token is stored in workflow data or emitted in logs;
- `direnv exec . just check` passes.

## Relationship to the Audit-Oriented MVP

This POC is a stepping stone, not a replacement for the existing audit design. It deliberately proves the most uncertain product behavior first: whether people find direct, researched answers in Bluesky threads useful.

The later MVP can reuse the durable mention identity, ancestor canonicalization, provider adapter, reply validator, and deterministic reply publication behavior. It will replace or extend the compact operational storage with intended ATProto records, blobs, audit projections, public viewing, stronger catch-up guarantees, and the full synchronization model described in `2026-07-27-context-bot-mvp-design.md`.

## Primary References

- [Bluesky notifications](https://docs.bsky.app/docs/api/app-bsky-notification-list-notifications)
- [Bluesky thread retrieval](https://docs.bsky.app/docs/api/app-bsky-feed-get-post-thread)
- [Bluesky labels and moderation](https://docs.bsky.app/docs/advanced-guides/moderation)
- [ATProto label specification](https://atproto.com/specs/label)
- [ATProto handle specification](https://atproto.com/specs/handle)
- [ATProto DID specification](https://atproto.com/specs/did)
- [Bluesky post Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/post.json)
- [Anthropic server tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools)
- [Anthropic web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
- [Anthropic web fetch](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-fetch-tool)
- [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
