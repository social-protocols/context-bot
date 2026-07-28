# Context Bot MVP Design

**Date:** 2026-07-27

## Goal

Build an on-demand Bluesky / ATProto context bot in the existing Elixir/Phoenix application. A user directly mentions the bot in a public thread and asks for context, verification, fairness, missing information, or a related assessment. The bot captures the invocation and its ancestor chain, researches the question with Claude's server-side web tools, constructs a complete auditable transcript, creates an intended ATProto audit graph locally, and asynchronously publishes that graph and a concise in-thread reply.

The MVP is reactive only. It does not proactively scan, moderate, label, rank, or reply to posts that do not directly mention the bot.

## Product Decisions

- Build one vertical slice in the existing Phoenix application. Do not introduce an umbrella, a separate worker service, LiveView, or a frontend application.
- Poll direct-mention notifications for MVP. Do not consume the firehose or Jetstream.
- Capture only the invocation post and its rootward ancestor chain. Do not fetch or include direct replies to the invocation post. This is an explicit product-scope decision: ancestors are the conversation visible before the question, while descendants are later reactions that can change after the bot is invoked.
- Use Claude's server-side `web_search` and `web_fetch` tools. Do not build a custom search crawler or client-side research loop.
- Normally use one Claude invocation for cited research and a delimited Bluesky-reply candidate. Make one conditional length-repair invocation only when that candidate is absent, malformed, or over budget.
- Reserve the audit-link suffix before prompting. Give Claude the remaining Unicode-grapheme budget as `N`, then render and validate the complete post deterministically.
- Enable Anthropic automatic prompt caching for research, provider continuations, and conditional length repair. Cache hits are an optimization, never a correctness dependency.
- Treat exact ATProto records and blobs as the canonical audit objects. Store their intended state, canonical bytes, AT URIs, and locally calculated CIDs in SQLite before attempting PDS publication.
- Treat PDS publication as asynchronous convergence of that intended ATProto state. A locally committed object with its final CID exists in the bot's content-addressed intended-object store even if it has not reached the PDS yet.
- Use a single `SYNC_TO_ATPROTO` switch rather than a separate dry-run model. When disabled, authentication, reads, and Claude calls continue while outgoing records/blobs remain durably queued and no profile, reply, or notification-seen mutation is sent.
- Use ATProto blobs for complete transcripts in MVP. Do not add IPFS to the publication path yet.
- Keep code organized around the concrete pipeline and protocol interfaces. Do not declare speculative Phoenix contexts or long-term business-domain boundaries in advance.

## End-to-End Flow

1. Authenticate the bot account with its DID and app password, and maintain an in-memory access/refresh session.
2. Poll `app.bsky.notification.listNotifications` with `reasons=mention`.
3. Validate that the notification contains an `app.bsky.feed.post`, the post is not authored by the bot, and a mention facet targets the bot DID.
4. Insert the notification into a durable inbox using `(invocation_uri, invocation_cid)` as its unique identity, then enqueue one run.
5. Fetch a bounded thread view for the invocation with replies disabled and an explicit parent-height limit.
6. Canonicalize the available ancestor path and invocation into the exact model input snapshot.
7. Invoke Claude once for cited web research, preserving the complete raw request, response, server-tool transcript, citations, usage, and attempt metadata.
8. Extract and validate the delimited Bluesky-reply candidate at the end of the research response.
9. If the candidate is missing, malformed, or over budget, append the complete response verbatim and invoke Claude once more only to produce a reply within the supplied budget.
10. Deterministically append the compact audit-link suffix and validate the complete reply's grapheme and byte limits.
11. Construct every prompt, snapshot, invocation, transcript, output, reply, run, publication, and Bluesky-post record locally. Calculate all blob and record CIDs before any ATProto mutation.
12. Commit the complete intended object graph and its dependency edges to SQLite.
13. If `SYNC_TO_ATPROTO=true`, asynchronously upload blobs and create records in topological order. If it is false, retain the graph unchanged until synchronization is enabled.

The audit page becomes available as soon as the intended graph is committed locally. It does not wait for PDS convergence.

## Mention Ingestion and Idempotency

The poller starts a scan from the newest notifications, pages backward, and ingests unseen mentions oldest-first. Pagination cursors are temporary API cursors, not permanent queue offsets, but an incomplete scan persists a catch-up cursor and the durable strong-reference boundary it is trying to reach. Later polling continues that catch-up scan before starting another newest-first scan. A configured page limit bounds one polling job, not the total catch-up range, so a notification burst cannot permanently hide older unseen mentions.

The durable mention identity is the pair of invocation URI and CID. A CID alone is insufficient because equal record content can occur at different AT URIs. A new CID at the same URI represents a new record version and may create a new run.

The MVP does not call `app.bsky.notification.updateSeen`. It is an unrelated account mutation and is not a processing acknowledgement.

The poller performs ingestion only. Claude calls, audit construction, and publication run in durable jobs. The initial processing and ATProto synchronization queues each use concurrency one to avoid overlapping work and SQLite contention. Concurrency can increase later based on measurements.

## Thread Capture and Canonicalization

Call `app.bsky.feed.getPostThread` for the invocation URI with:

- `depth=0`, so no replies are requested;
- a configured `parentHeight`, initially 80;
- an HTTP response-size limit and request timeout.

The canonical sequence is:

1. available ancestors in root-to-parent order;
2. the invocation post.

The canonicalizer handles `threadViewPost`, `notFoundPost`, `blockedPost`, and unknown future union variants. Missing positions remain explicit placeholders rather than disappearing. A not-found result is described as unavailable, not definitively deleted. A truncation marker is included whenever the returned data indicates that another ancestor or root exists but was not captured.

For each available post, preserve the AT URI, CID, author DID and handle as observed, creation timestamp, text, and the original bounded record/view JSON. The model receives a deterministic plain-text representation with a versioned canonicalization identifier. It does not receive descendant replies.

Embeds may be described textually from available metadata, but the bot does not inspect image, audio, or video content in MVP. If the question depends on unsupported media and public text sources cannot resolve it, the answer says so.

## Claude Research and Reply Generation

### Pinned API contract

Use the direct Anthropic Messages API with:

- `anthropic-version: 2023-06-01`;
- model `claude-sonnet-5`, configurable through `ANTHROPIC_MODEL_ID`;
- `web_search_20260318`, configurable through `ANTHROPIC_WEB_SEARCH_TOOL_VERSION`;
- `web_fetch_20260318`, configurable through `ANTHROPIC_WEB_FETCH_TOOL_VERSION`.

Leave temperature, `top_p`, and `top_k` unset. Sonnet 5 rejects non-default sampling parameters. Prompt instructions, strict local validation, and a bounded repair path provide the desired consistency without claiming deterministic replay.

### Research invocation

The first invocation uses:

- versioned system and safety prompts;
- the canonical thread snapshot and invocation question;
- adaptive thinking with display omitted;
- high effort;
- `web_search` and `web_fetch` with direct callers only;
- full response inclusion;
- citations enabled;
- fetch cache bypassed;
- Anthropic automatic prompt caching with the default five-minute TTL;
- explicit per-run search, fetch, continuation, token, and response-size limits.

The raw first response is the authoritative provider transcript. Preserve ordered content blocks, opaque thinking signatures, encrypted tool content, server-tool uses and results, citations, errors, request IDs, stop reasons, container details, and usage. The system must not claim to expose hidden chain-of-thought.

If Anthropic returns `pause_turn`, append the complete assistant content unchanged and continue with the same model, prompts, and tool configuration. Enforce aggregate run budgets across continuations because provider `max_uses` limits apply per HTTP request. These provider continuations are part of the primary research invocation and do not consume the one optional length-repair invocation.

The prompt asks for ordinary cited research prose followed by exactly one terminal sentinel block:

```text
BEGIN_BLUESKY_REPLY
candidate text
END_BLUESKY_REPLY
```

The marker lines are not part of the candidate and are never posted. The candidate excludes the audit-link suffix. Before the invocation, the renderer calculates `N` as 300 minus the grapheme length of the exact separator and visible audit-link suffix. The prompt supplies `N` and asks Claude to keep the candidate within it.

The extractor accepts a candidate only when there is exactly one ordered begin/end marker pair, the block is terminal except for trailing whitespace, the enclosed text is nonempty, neither marker is nested or duplicated, and no marker text remains in the candidate. The candidate must be plain text suitable for a Bluesky post. The validator then requires it to use at most `N` Unicode grapheme clusters and the complete rendered post to use at most 300 grapheme clusters and 3,000 UTF-8 bytes. The ordinary research prose remains the visible, cited audit explanation; no rigid result schema is required.

### Conditional length-repair invocation

If the primary candidate fails extraction or validation, make at most one length-repair invocation. Resend the complete accumulated Messages conversation, including every assistant content block verbatim, and append one final user message directing Claude to return only a Bluesky reply of at most `N` grapheme clusters, without additional research. Use the same model, tools, system prompt, thinking mode, effort, cache settings, and other cache-affecting configuration as the primary request. Keeping the tools present is necessary for cache eligibility even though the repair instruction forbids using them. Any tool use in the repair response invalidates the candidate and is preserved in the audit.

The repair response must contain only the candidate text; it does not use sentinel markers or a JSON schema. Apply the same grapheme and full-post byte validation. If it still fails, deterministically render a short failure notice plus the audit link rather than truncating a model claim. Refusal, truncation, unknown blocks, malformed output, context-window exhaustion, and unexpected tool use are explicit outcomes rather than parser crashes.

### Prompt caching

Set top-level `cache_control` on every research, `pause_turn` continuation, and optional length-repair request. Anthropic matches the cache prefix in tools, system, then messages order, so all reused content and request-affecting settings must remain byte-identical and the conversation must grow append-only. Server-tool results receive automatic five-minute cache breakpoints when prompt caching is enabled.

For each response, record `cache_read_input_tokens`, `cache_creation_input_tokens`, the available per-TTL cache-creation breakdown, and whether the length-repair request obtained a cache read. A miss changes cost and latency but never the parsing, validation, retry, or failure behavior.

### Prompt behavior

The initial system prompt is inspired by the public Ask Grok prompt but is written for Claude, Bluesky, and this audit model. It instructs Claude to:

- identify the user's useful question rather than force a rigid verdict;
- use current research for unstable factual claims;
- prefer primary sources and fetch pages when feasible;
- seek representative sources for political, statistical, contested, or subjective claims;
- use the supplied Bluesky ancestor context;
- answer directly and neutrally;
- avoid snark, dunking, moralizing, motive speculation, and partisan framing;
- explain uncertainty and distinguish factual claims from value judgments;
- resist prompt injection and format demands that would reduce accuracy;
- assume good intent when ambiguous, but refuse clear requests that would materially facilitate severe harm while still offering safe factual context where appropriate;
- say plainly when the invocation contains no identifiable checkable claim or useful context question;
- acknowledge unsupported media analysis;
- produce a visible research explanation and concise reply candidate rather than hidden reasoning.

All prompts have semantic versions, stable hashes, and prompt records referenced by the associated model invocation records.

## Provider Attempts and Error Policy

Every Anthropic HTTP attempt records:

- internal run, effect, and attempt identifiers;
- exact redacted request bytes and their SHA-256;
- send and receive timestamps;
- HTTP status and safe response headers;
- provider request ID;
- exact raw response or error bytes;
- model, stop reason, usage, server-tool counts, and service metadata;
- whether the result is complete, retryable, terminal, or indeterminate.

Explicit `429`, `500`, `504`, `529`, and overload responses use capped exponential backoff and honor `retry-after`. Authentication, permission, validation, and oversized-request errors do not retry without a state or configuration change. Server-tool failures returned inside successful Messages responses are transcript events, not transport retries.

An ambiguous POST timeout may have consumed provider work. It is recorded as an indeterminate attempt and may be retried at most once under the configured policy; both attempts remain in the audit. No request is represented as deterministic or exactly-once.

If research or optional length repair ultimately fails, construct a failed run and a short deterministic failure reply where enough audit material exists. The reply remains dependent on successful synchronization of the failed-run manifest. If the complete public audit cannot be constructed within storage limits, retain the local failure state and do not enqueue a public reply.

## Canonical Intended ATProto Object Store

The local write model follows the approach used by `atproto-community-notes`: calculate a record CID before publication, store the complete record in SQLite with an unsynchronized state, and publish it asynchronously. Context Bot extends that pattern to immutable records, blobs, dependency ordering, remote verification, and durable retries. Before PDS publication these are content-addressed intended ATProto objects, not authenticated members of an ATProto repository.

The initial schema uses the main application SQLite database so an entire run graph can be committed atomically. Splitting intended ATProto state into another SQLite file would introduce a cross-database consistency boundary without a demonstrated MVP benefit.

The existing single Fly volume and 14-day snapshots remain an explicit MVP durability tradeoff. They do not guarantee survival of unsynchronized intent after host or volume loss. Synchronization should normally keep that exposure window short; if synchronization is deliberately disabled for an extended period, the operator must take an online SQLite backup before treating the accumulated state as independently durable. Multi-Machine SQLite replication and external backup infrastructure remain deployment follow-ups rather than hidden guarantees.

### Intended record storage

`atproto_records` stores:

- repository DID, collection, rkey, and unique AT URI;
- canonical Lexicon JSON;
- canonical DAG-CBOR bytes;
- locally calculated record CID;
- object kind and creation timestamp;
- synchronization state;
- remote CID and synchronization timestamp when converged;
- last categorized synchronization error.

Canonical audit and reply records are immutable after insertion. Any correction or retraction creates a new record and links to the previous run. Mutable administrative records such as the bot profile use an explicit replacement policy and are not part of the immutable audit DAG.

### Intended blob storage

`atproto_blobs` stores:

- raw CIDv1/SHA-256 blob CID;
- MIME type and byte size;
- exact encoded bytes;
- logical document identifier and chunk order;
- synchronization state and remote verification details.

The blob CID, byte size, and intended MIME type are computable before upload. A record can therefore contain its intended blob objects before either the blobs or record have reached the PDS. The PDS may sniff and return a different MIME type; any difference is reconciled before the referencing record is considered publishable.

### Dependencies and attempts

`atproto_dependencies` stores record-to-record strong-reference edges and record-to-blob edges. The graph must be acyclic and all dependencies must exist locally before a dependent object is committed.

`atproto_sync_attempts` stores each upload or record-creation attempt, result, timing, and categorized failure. Pending objects are never discarded because synchronization is disabled or temporarily failing.

The operational inbox, run checkpoint, provider attempts, Oban jobs, and intended ATProto object tables remain separate technical concerns within the same database. These tables do not establish permanent application-domain boundaries.

## ATProto Record Namespace and Graph

All project records use the controlled namespace `org.social-protocols.contextbot.*`, corresponding to Lexicon authority at `contextbot.social-protocols.org`.

The MVP defines:

- `org.social-protocols.contextbot.prompt`;
- `org.social-protocols.contextbot.threadSnapshot`;
- `org.social-protocols.contextbot.modelInvocation`;
- `org.social-protocols.contextbot.toolTranscript`;
- `org.social-protocols.contextbot.modelOutput`;
- `org.social-protocols.contextbot.renderedReply`;
- `org.social-protocols.contextbot.run`;
- `org.social-protocols.contextbot.publication`;
- shared definitions under `org.social-protocols.contextbot.defs`.

The core contents are:

| Record | Core contents |
|---|---|
| `prompt` | Prompt kind, semantic version, inline text or document manifest, decoded SHA-256, and creation time. |
| `threadSnapshot` | Invocation and root strong references, ordered ancestor strong references, unavailable placeholders, canonical text document, bounded original response document, fetch parameters, canonicalization version, fetch time, and creation time. There are no descendant-reply fields in MVP. |
| `modelInvocation` | Invocation kind (`research` or `lengthRepair`), provider, pinned model, public request-projection document, full internal request digest, prompt strong references, thread-snapshot strong reference, tool and cache configuration, parameter name/value pairs, redaction-policy version, and request time. An optional length-repair invocation also references the primary research output whose candidate failed validation. |
| `toolTranscript` | Invocation strong reference, parsed public transcript-projection document, search/fetch/citation summaries, content digests, tool failures, policy version, and creation time. There is one for the research invocation and, only if the repair unexpectedly uses a tool, one for the repair invocation. The complete redacted Anthropic responses remain authoritative in restricted local storage. |
| `modelOutput` | Invocation strong reference, output kind (`research` or `lengthRepair`), public response-projection document, full internal response digest, visible provider text, extracted candidate and validation outcome, source summaries, cache usage, limitations, stop reason, and creation time. There is always one primary output and at most one repair output. |
| `renderedReply` | Chosen model-output strong reference, deterministic renderer name/version, final text, grapheme count, UTF-8 byte count, audit URL, and creation time. |
| `run` | Status, invocation-post strong reference, all prompt/snapshot/invocation/transcript/output/reply strong references available for that status, start/completion times, optional failure document, and optional `supersedes` strong reference. |
| `publication` | Run strong reference, Bluesky reply-post strong reference, and creation time. |

Every record-to-record edge uses the `com.atproto.repo.strongRef` shape containing both AT URI and CID. Run-related records use a preallocated TID as their rkey where the Lexicon permits it, allowing predictable audit URLs and related URIs across collections. Semantic prompt versions use stable `any` record keys.

Record CIDs identify canonical content, while ATProto repository commits authenticate repository state through the account's signature. The design does not describe individual records as separately signed objects. The local intended-object store establishes the exact content and CID; PDS convergence includes that content in signed repository state at a point in time. ATProto does not provide an append-only permanent record history or guarantee continued availability after deletion, takedown, account loss, or PDS data loss.

The graph is:

```text
prompts       threadSnapshot
   \              /
    modelInvocation (research) ---- toolTranscript
                 |
       modelOutput (research)
                 |
          candidate valid?
             /       \
           yes        no
            |          |
            |    modelInvocation (lengthRepair)
            |          |
            |    modelOutput (lengthRepair)
            \          /
             renderedReply
                  |
                 run <---- toolTranscript(s)

run --sync prerequisite--> reply post

run -----------\
                publication
reply post ----/
```

The final two lines represent synchronization dependencies: the reply waits for the run, and publication contains strong references to both the run and reply. The reply itself contains the stable HTTPS audit URL rather than a strong reference to the run, avoiding a CID cycle.

The exact graph is built locally before synchronization. The PDS synchronization order is blobs, prompts and leaf records, dependent component records, run, Bluesky reply, then publication.

The `run` status uses extensible known values such as `complete`, `failed`, `corrected`, and `retracted`. Corrected and retracted runs are new immutable manifests with a `supersedes` strong reference; original records are not rewritten.

Custom Lexicon documents live in the repository and are validated locally. They will also be published as `com.atproto.lexicon.schema` records with the required `_lexicon.social-protocols.org` authority before remote validation is required. Until that authority is available, custom record writes use optimistic PDS validation while preserving strict local validation.

## Large Audit Documents

Public request/response projections, canonical thread text, parsed public tool transcripts, and long model outputs use a shared ATProto document manifest rather than large inline strings. Complete internal provider artifacts use the same deterministic serialization, digest, compression, and chunking rules in restricted local storage but are not automatically queued for public synchronization.

The manifest contains:

- media type;
- content encoding, initially `identity` or deterministic `gzip`;
- decoded byte length and SHA-256;
- encoded byte length;
- ordered ATProto blob chunks.

Serialization and redaction happen before hashing or compression. Deterministic gzip uses fixed metadata, and the encoded stream is divided into fixed 4 MiB chunks. The initial application caps are 20 MiB encoded and 64 MiB decoded per logical document, both configurable. Silent truncation is forbidden.

Records should remain only a few dozen kilobytes. ATProto's current interoperability guidance gives a one-MiB CBOR ceiling, but individual PDS operators may impose their own blob sizes and account quotas.

If a complete audit document exceeds the configured cap, store the local failure metadata, block public synchronization of the incomplete graph, and do not publish a reply that claims to have a complete audit.

## Internal Transcript and Public Artifact Policy

The complete redacted Anthropic request and response transcript is retained in restricted local storage for operational audit. Public ATProto artifacts are a deterministic, versioned projection of that transcript. Full third-party bodies omitted from the public projection are recoverable only from the protected SQLite backup/retention path, not from the PDS audit graph; the viewer states that limitation explicitly.

The public projection preserves:

- every message, content-block type, tool invocation, tool outcome, stop reason, retry, usage field, and provider request ID;
- complete model-authored visible text, extracted candidates, and validation outcomes;
- search queries, result URLs/titles/page ages, citations, and returned citation excerpts;
- fetch URLs, titles, retrieval times, citation locations, content sizes, MIME types, and SHA-256 hashes;
- explicit placeholders describing every redaction or omitted payload.

The public projection does not automatically republish complete third-party fetched pages or PDF bytes. Those bodies may contain copyrighted works, personal data, malware payloads, or material removed by its publisher. Their exact redacted bytes remain internal; the public audit exposes their digest, size, source metadata, citation excerpts, and the model output that used them. Public raw JSON downloads are therefore byte-exact for the public projection, not falsely described as the untouched provider response when third-party bodies were omitted.

Credential and secret redaction occurs before either internal retention or public projection. A versioned policy also rejects private-network URLs, credential-bearing URLs, cookies, authorization material, and unsupported active content. Every public omission is visible and machine-readable; silent mutation is forbidden.

Audit records are immutable during ordinary operation, but immutability does not override safety, legal, privacy, or account-takedown obligations. An operator can execute an explicit emergency takedown that stops synchronization or deletes affected public records/blobs, records the reason locally, and publishes a retraction marker when possible. The viewer reports takedown or unavailability without claiming that third-party archives have removed prior public copies.

## Why IPFS Is Deferred

IPFS is not part of the MVP publication path. It improves distribution only when Context Bot or independent providers operate durable pins and production gateways; a CID alone does not guarantee that any provider retains the bytes. Adding it now would create another upload queue, credential set, reconciliation process, retrieval monitor, gateway dependency, and privacy/retraction risk while ATProto already supplies content-addressed blobs.

Reconsider a hybrid only if production measurements show one or more of:

- normal complete documents repeatedly exceed tested PDS limits;
- audit growth creates unacceptable PDS account-quota pressure;
- independent availability after loss of the bot PDS becomes an explicit requirement;
- third parties need protocol-level mirroring by content identifier.

In a future hybrid, ATProto remains the signed discovery and manifest layer. IPFS is an optional oversized-document replica described by a fixed import profile, `ipfs://` URI, media type, encoding, decoded size, and plain SHA-256. A typical UnixFS root CID is not stored as an ATProto `cid-link`; it is a validated string because current ATProto CID-link validation allows only the raw and DAG-CBOR codecs. An IPFS location is advertised only after the complete DAG is pinned and independently retrievable.

## Backpressure, Abuse, and Cost Controls

Any public account can mention the bot, and Claude research remains billable even when ATProto synchronization is paused. Queue concurrency alone is not an abuse boundary.

Before starting a research invocation, enforce configurable controls for:

- per-actor request count and cooldown;
- global requests and estimated provider spend per rolling period;
- maximum pending/deferred run count;
- maximum unsynchronized ATProto bytes;
- minimum free SQLite-volume bytes or percentage;
- maximum invocation, ancestor-chain, provider-response, and logical-document sizes.

The poller may continue durably ingesting small mention receipts after a threshold trips, but it marks new work deferred and does not call Claude or create large artifacts. Operator-visible health state and structured alerts identify the limiting threshold. Recovery resumes deferred work oldest-first after the condition clears, subject to the same actor and global budgets. A manual administrative control can pause research independently of `SYNC_TO_ATPROTO` without discarding inbox state.

## Asynchronous ATProto Synchronization

`SYNC_TO_ATPROTO` defaults to `false` in development and test. Production also requires an explicit value; possessing credentials alone never enables mutation.

When disabled:

- notification and thread reads continue;
- Claude research continues;
- canonical records and blobs are created locally;
- audit pages remain available;
- no blobs, custom records, profile records, or reply posts are sent to ATProto.

When enabled, a durable worker repeatedly selects dependency-ready pending objects. Records use explicit deterministic rkeys and create-only semantics.

Blob state distinguishes `pending`, `uploaded_temporary`, and `referenced`. An uploaded blob is temporary and is not considered converged until at least one successfully created record references it. The worker uploads the chunks for a document immediately before its first referencing record rather than uploading an unbounded blob backlog. If record creation reports a missing temporary blob, the worker re-uploads the exact local bytes and retries the record.

For each blob upload, require the returned CID, MIME type, and size to match the local intended object. For each record creation, require the returned URI and CID to match the locally computed values. After an ambiguous network result or create conflict, fetch the deterministic URI and accept it only if the remote CID and record content match. A mismatch blocks the object and all dependents and produces an operator-visible alert; it is never overwritten silently.

The reply post is an ordinary intended `app.bsky.feed.post` record and depends on the local `run` record. The `publication` record depends on both. This guarantees that no reply becomes visible before its audit manifest can become visible and prevents duplicate replies after crashes.

Temporary PDS failures retry indefinitely with bounded exponential backoff. Permanent policy, validation, quota, or CID-conflict failures remain durable and blocked for operator action rather than being discarded.

## Reply Construction

The reply is derived deterministically from the valid primary candidate or, only when needed, the valid length-repair output. It includes the exact reserved separator and compact HTTPS audit-link suffix. It is not forced into a fixed true/false taxonomy. Appropriate forms include qualified support, lack of evidence, missing context, mixed evidence, and non-checkable value judgments.

Before local insertion, enforce both Bluesky limits:

- at most 300 Unicode grapheme clusters;
- at most 3,000 UTF-8 bytes.

Elixir's `String.length/1` and `String.slice/3` provide grapheme-safe counting and shortening. Rich-text facet offsets are calculated after final rendering as zero-based UTF-8 byte offsets. The post includes:

- `text` and `createdAt`;
- `reply.parent` referencing the invocation post;
- `reply.root` copied from the invocation's root reference, or the invocation itself when it is the root;
- a link facet covering the visible audit-link text.

Renderer tests cover combining marks, zero-width-joiner emoji, skin tones, flags, non-Latin scripts, and multibyte characters immediately before the link facet.

The renderer never truncates a model-authored factual claim to make it fit. It either uses a fully valid candidate or emits the versioned deterministic failure notice. This keeps the meaning of the published answer attributable to a complete model output.

## Public Audit Viewer

Phoenix serves minimal server-rendered pages; LiveView is unnecessary. The primary route is a stable audit URL based on the run rkey, with additional raw-artifact download routes.

The viewer reads intended ATProto records and blobs from SQLite so it works immediately and remains available while synchronization is disabled or delayed. It shows ordinary object synchronization state, not a separate dry-run label.

For synchronized objects, the viewer verifies the current PDS representation and visibly reports missing records, unavailable blobs, or CID mismatches. If a synchronized run is absent from local SQLite after recovery or cache loss, the viewer can resolve the run record by bot DID and rkey, follow its exact strong references, fetch referenced blobs from the current PDS, verify every expected CID/hash/length, and repopulate a local read-through cache. Published audit links therefore do not depend permanently on the original Fly volume. If both the local object and PDS representation are available, the page distinguishes intended state from observed PDS convergence rather than silently choosing divergent content.

The page shows:

- final short reply and run status;
- original invocation and ancestor-only thread snapshot;
- prompt versions and full prompt text;
- provider, pinned model ID, and request parameters;
- the primary Claude invocation and optional length-repair invocation;
- visible long research answer, extracted candidates, and validation results;
- web-search and web-fetch transcript returned by Anthropic;
- citations, tool failures, limitations, and stated uncertainty;
- raw redacted requests, responses, and derived artifacts;
- AT URIs, CIDs, strong references, blob manifests, and synchronization state.

The page explicitly says that hidden Claude reasoning is unavailable and is not part of the transparency claim. All external content is escaped, raw artifacts are served with safe content types and download headers, and the viewer uses strict CSP and response-size bounds.

## Runtime Configuration and Secrets

Expected non-secret configuration includes:

- `BOT_DID`;
- `BOT_HANDLE`;
- `BOT_PDS_URL`;
- `AUDIT_BASE_URL`;
- `SYNC_TO_ATPROTO`;
- `MENTION_POLL_INTERVAL_MS`;
- `THREAD_PARENT_HEIGHT`;
- `ANTHROPIC_MODEL_ID`;
- `ANTHROPIC_RESEARCH_MAX_TOKENS`;
- `ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS`;
- `ANTHROPIC_WEB_SEARCH_TOOL_VERSION`;
- `ANTHROPIC_WEB_FETCH_TOOL_VERSION`;
- `MAX_WEB_SEARCH_USES`;
- `MAX_WEB_FETCH_USES`;
- `MAX_WEB_FETCH_CONTENT_TOKENS`;
- `MAX_TOOL_CONTINUATIONS`;
- `MAX_ACTOR_REQUESTS_PER_WINDOW` and actor cooldown;
- `MAX_GLOBAL_REQUESTS_PER_WINDOW` or provider-spend budget;
- `MAX_PENDING_RUNS` and `MAX_UNSYNCED_ATPROTO_BYTES`;
- `MIN_FREE_VOLUME_BYTES` or percentage;
- document size and chunk-size limits.

Secrets include `ANTHROPIC_API_KEY` and `BOT_APP_PASSWORD`. They are added deliberately to the Bitwarden allowlist and Fly runtime secrets. Access and refresh JWTs remain in memory and are never written to SQLite, logs, or audit objects.

Session refresh is serialized. A restart creates a new session with the app password rather than persisting tokens. Logs never contain authorization headers, API keys, cookies, passwords, or complete HTTP request structs.

The bot profile must identify the account as an AI context bot powered by Claude and state that prompts and audit logs are public. Profile creation or replacement uses an explicit administrative command and the same synchronization mechanism rather than an implicit startup mutation.

## Elixir Technical Shape

The application uses explicit protocol ports and adapters without promoting them into speculative business contexts:

- `Req` over a supervised `Finch` pool for Anthropic and ATProto HTTP;
- narrow project-owned XRPC builders and parsers for only the required endpoints;
- a supervised ATProto session process;
- Oban with `Oban.Engines.Lite` for durable SQLite jobs;
- pure thread canonicalization, record construction, CID calculation, candidate extraction, and reply-rendering functions;
- strict local validation for primary and length-repair reply candidates;
- structured JSON logging with an application redaction boundary;
- `Req.Test` for wire-level HTTP contracts and Mox for semantic adapter behavior.

The implementation initially groups modules by concrete responsibility and may revise boundaries after the vertical slice reveals stable concepts. No third-party Elixir ATProto client becomes a domain dependency. Project-owned AT URI, TID, strong-reference, Lexicon-to-IPLD, canonical DAG-CBOR, and CID interfaces may use small vetted generic CBOR/CID libraries where compatible; every result is verified against official fixtures and cross-language test vectors rather than trusting an unverified encoding path.

The supervision tree retains the existing repository, telemetry, PubSub, and Phoenix endpoint and adds the Finch pool, Oban, ATProto session manager, and non-overlapping mention poller. External HTTP calls never occur inside SQLite transactions.

## Testing Strategy

Implementation follows behavior-first ExUnit development. Each feature test is observed failing for the intended reason before implementation.

Pure tests cover:

- mention facet and self-post filtering;
- notification pagination, multi-job catch-up across the page limit, restart recovery, and duplicate suppression;
- ancestor-only thread ordering and canonicalization;
- blocked, unavailable, truncated, and unknown thread variants;
- deterministic gzip, chunking, DAG-CBOR, local record CIDs, blob CIDs, AT URIs, TIDs, and strong references;
- prompt versioning and hashes;
- primary candidate extraction for valid, missing, duplicate, nested, and empty sentinel blocks;
- reserved-suffix budget calculation and complete-post grapheme and byte validation;
- valid primary candidates skipping length repair and invalid candidates causing exactly one repair attempt;
- byte-identical cached request prefixes, verbatim assistant-message continuation, cache-usage capture, and invalidation on unexpected repair tool use;
- invalid repair output producing the deterministic failure reply without claim truncation;
- no-checkable-claim and severe-harm safety fixtures;
- renderer grapheme limits and facet byte offsets;
- custom Lexicon builders and no-float ATProto validation;
- intended graph acyclicity and dependency order.

HTTP contract tests cover:

- exact XRPC methods, paths, queries, auth, and payloads;
- session refresh without credential leakage;
- Anthropic headers, model/tool versions, and request bodies;
- automatic `cache_control` on research, continuation, and repair requests, with an unchanged cached prefix;
- search, fetch, citation, continuation, refusal, truncation, overload, timeout, and unknown-block responses;
- blob uploads and returned metadata verification;
- temporary blob re-upload after expiry or missing-blob rejection;
- record creation, conflict reconciliation, and CID mismatch blocking.

Durability tests cover:

- one job per invocation URI/CID;
- resume from every stage checkpoint;
- crash injection after every provider and synchronization effect;
- disabled synchronization retaining all objects;
- enabling synchronization draining the complete backlog in topological order;
- deterministic reply keys preventing duplicate posts;
- permanent failures blocking dependents without data loss;
- actor/global budget enforcement, spam bursts, disk watermarks, and prolonged PDS outage backpressure;
- audit pages rendering entirely from intended local state;
- synchronized audit rehydration from PDS after local database/cache loss.

Golden fixtures include official Lexicon-shaped notifications and thread views, blocked/unavailable variants, raw Anthropic tool responses, and Unicode edge cases. The complete `just check` gate remains required before completion claims.

## Delivery Milestones

The MVP is delivered as one feature branch through four sequential milestones:

1. **Durable ingestion and intended-object store:** configuration, ATProto reads/authentication, mention inbox, ancestor-only thread capture, Oban, local record/blob/CID primitives, `SYNC_TO_ATPROTO=false`, and local audit skeleton.
2. **Claude research and rendering:** prompts, the primary research invocation, conditional cache-enabled length repair, complete attempt capture, candidate validation, deterministic reply rendering, and failed-run behavior.
3. **ATProto graph and synchronization:** custom Lexicons, complete immutable audit graph, deterministic document chunking, dependency-aware PDS sync, remote verification, reply posts, publication records, and profile setup command.
4. **Audit viewer and hardening:** complete public pages and raw artifacts, synchronization diagnostics, security headers, failure recovery, monitoring, deployment configuration, and end-to-end acceptance tests.

Each milestone is testable end to end and leaves the branch in a verified state. The implementation plan will break these milestones into small TDD tasks with exact files and commands.

## Acceptance Criteria

The MVP is complete when:

- a public Bluesky user can trigger one run by directly mentioning the bot;
- the bot never initiates proactive moderation or unmentioned replies;
- the captured context contains only the invocation and rootward ancestors;
- all transformations from thread input through the primary and any optional length-repair invocation to the final reply are retained;
- the complete redacted Anthropic requests, responses, server tools, citations, errors, retries, and usage are auditable;
- every intended ATProto record and blob has its final AT URI or blob identity and locally calculated CID before network publication;
- `SYNC_TO_ATPROTO=false` publishes no records or blobs and mutates no profile, reply, or notification-seen state while preserving the full intended graph;
- enabling synchronization drains dependency-ready objects in deterministic test fixtures within bounded worker executions and verifies remote CIDs without duplicate replies;
- every visible reply fits Bluesky's limits and contains an audit link that returns HTTP 200 with the expected run CID and status;
- the audit page shows intended objects immediately and their observed synchronization state;
- a synchronized audit remains resolvable and can repopulate its local cache after simulated SQLite loss;
- the audit page exposes prompts, ancestor snapshot, model IDs, parameters, visible analysis, sources, public tool-transcript projection, raw public JSON, final reply, AT URIs, CIDs, and strong references;
- the complete redacted provider transcript remains available to authorized operators under the configured local backup/retention policy, while public omissions carry hashes, metadata, and explicit reasons;
- the audit page does not imply access to hidden chain-of-thought;
- published Lexicons resolve through `_lexicon.social-protocols.org` and validate every custom record shape;
- abuse, cost, backlog, and disk thresholds defer research without losing mention receipts and resume it predictably after recovery;
- Claude and PDS failures produce durable, understandable states, and incomplete oversized audits never publish a misleading reply;
- no credentials, tokens, cookies, or secrets appear in logs, SQLite audit content, blobs, ATProto records, or public pages.

## Non-Goals

- Proactive scanning, moderation, labeling, or unsolicited replies
- Firehose or Jetstream consumption
- Direct replies or other descendants in the captured thread window
- Custom feeds, labelers, consensus ranking, or a Community Notes replacement
- Image, audio, or video interpretation
- A custom crawler, search index, or client-side research agent
- Formal true/false verdict categories
- Raw chain-of-thought collection or claims
- Deterministic model replay guarantees
- IPFS, Filecoin, or another secondary public storage network in the MVP
- Multiple Phoenix applications, an umbrella, LiveView, or a JavaScript frontend
- Finalized long-term domain/context boundaries

## Primary References

- [Anthropic model IDs and versions](https://platform.claude.com/docs/en/about-claude/models/model-ids-and-versions)
- [Anthropic server tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/server-tools)
- [Anthropic web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)
- [Anthropic web fetch](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-fetch-tool)
- [Anthropic citations](https://platform.claude.com/docs/en/build-with-claude/citations)
- [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [Anthropic tool use with prompt caching](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching)
- [ATProto repository](https://atproto.com/specs/repository)
- [ATProto blobs](https://atproto.com/specs/blob)
- [ATProto data validation](https://atproto.com/guides/data-validation)
- [ATProto Lexicon](https://atproto.com/specs/lexicon)
- [Bluesky post Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/post.json)
- [IPFS persistence and pinning](https://docs.ipfs.tech/concepts/persistence/)
- [IPFS privacy and encryption](https://docs.ipfs.tech/concepts/privacy-and-encryption/)
