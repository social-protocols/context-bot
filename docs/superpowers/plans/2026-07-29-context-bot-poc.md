# Context Bot Proof-of-Concept Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved live POC loop: an eligible actor directly mentions the public Bluesky bot, the application durably captures the invocation and rootward ancestors, Claude researches it with server-side web tools, and the bot publishes exactly one concise reply.

**Architecture:** Extend the existing single Phoenix application with a SQLite-backed staged workflow. A supervised ATProto session and notification poller ingest mentions; Oban Lite runs eligibility, thread, research, reply, and deferred-work stages. Each stage commits its output before enqueueing the next. Req uses one supervised Finch pool for ATProto and Anthropic HTTP, while narrow client behaviours keep contract tests deterministic. The modules below describe concrete pipeline responsibilities, not permanent business-domain boundaries.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix 1.8.9, Ecto/SQLite, Oban 2.23 Lite engine, Req 0.7.1, Finch 0.23, Jason, ExUnit, Req.Test, Devbox, direnv, just, Fly.io, Bitwarden CLI.

## Global Constraints

- Work only in `.worktrees/context-bot-mvp` on `codex/context-bot-mvp` until the complete branch is explicitly integrated.
- Run every project command as `direnv exec . <command>`.
- Develop custom behavior red-green: add one focused failing test, observe the intended failure, implement only that behavior, and observe it pass.
- Keep the application API-only. Add no UI, LiveView, audit route, audit link, custom ATProto Lexicon, blob, IPFS integration, or `org.social-protocols.contextbot.*` record.
- Treat the invocation `(AT URI, notification CID)` strong reference as the durable ingestion identity, matching the approved design. Retain the current fetched CID separately when the AppView reports a changed record.
- Include the invocation and rootward ancestors only. `getPostThread` must send `depth=0`; never traverse `replies`.
- Never make external HTTP calls inside an Ecto transaction.
- Persist each stage output and the next Oban job atomically. Workers must skip already-completed effects.
- Every worker must resume its own persisted in-progress state (`checking_eligibility`, `capturing_thread`, `researching`, or `publishing`) after a retry or recovery job; claiming a stage must never make that worker ineligible to continue it.
- Keep all database tests synchronous because the SQLite sandbox does not support concurrent writers.
- Never log or persist app passwords, API keys, access JWTs, refresh JWTs, authorization headers, or whole request structs.
- Persist the complete raw body of every Anthropic HTTP response, successful or erroneous, before interpreting it. Do not truncate or replace it with a parsed projection.
- Enforce `ANTHROPIC_RESPONSE_MAX_BYTES < PROVIDER_RESPONSE_STORAGE_MAX_BYTES`; reject an oversized response at the HTTP boundary before parsing.
- Use integer microdollars for costs. Never use floats for budget or pricing math.
- Make no Anthropic request without an atomic daily-budget reservation.
- Freeze the exact post record and a valid 13-character TID rkey before the first PDS write. Reconcile with `getRecord` before and after ambiguous `putRecord` results.
- Terminal failures are locally inspectable and silent on Bluesky.
- Commit each task separately with the specified message. Run `direnv exec . just check` before each task commit and again at the end.
- Do not run `just deploy` or perform a live public smoke test without explicit authorization.

---

## File Map

### Runtime and infrastructure

- `mix.exs`, `mix.lock` — add Req, Finch, and Oban; pin the SQLite adapter range.
- `config/config.exs` — queues, plugins, safe defaults, Finch client options, and concrete adapter modules.
- `config/dev.exs`, `config/test.exs`, `config/runtime.exs` — disabled-by-default local bot, manual Oban tests, strict production environment parsing.
- `lib/context_bot/application.ex` — supervise Repo, Finch, Oban, session, poller, and endpoint in dependency order.
- `lib/context_bot/settings.ex` — validated runtime settings struct used by workers and supervisors.
- `priv/repo/migrations/20260729000000_create_poc_workflow.exs` — Oban and invocations.
- `priv/repo/migrations/20260729001000_create_api_budget_entries.exs` — Anthropic reservation/settlement ledger.
- `test/support/data_case.ex` — Oban test helpers.

### Durable workflow

- `lib/context_bot/workflow/invocation.ex` — operational invocation schema and status validation.
- `lib/context_bot/workflow/store.ex` — idempotent receipt insertion, stage transitions, response retention, and atomic handoffs.
- `lib/context_bot/workflow/failure.ex` — finite safe error categories written to state/logs.
- `lib/context_bot/workers/{eligibility,thread,research,reply,deferred}_worker.ex` — one durable effect per worker.

### ATProto and ingestion

- `lib/context_bot/atproto/client.ex` — behavior consumed by pipeline modules.
- `lib/context_bot/atproto/req_client.ex` — XRPC requests and response classification.
- `lib/context_bot/atproto/session.ex` — serialized in-memory session creation/refresh.
- `lib/context_bot/atproto/{at_uri,strong_ref,tid,post}.ex` — validation and record construction.
- `lib/context_bot/mentions/{validator,poller}.ex` — direct-mention validation and newest-first overlapping drains.

### Eligibility and admission

- `lib/context_bot/eligibility.ex` — operator allowlist, Skywatch Elder, and bidirectional `bsky.team` checks.
- `lib/context_bot/admission.ex` — atomic actor/global rolling limits and pending-capacity decisions.

### Thread and Claude

- `lib/context_bot/thread/canonicalizer.ex` — deterministic root-to-invocation model input.
- `lib/context_bot/money.ex` — strict decimal-USD to microdollar conversion.
- `lib/context_bot/research/{budget_entry,budget,pricing}.ex` — reservation/exposure ledger and Sonnet price version.
- `lib/context_bot/research/{client,anthropic_client,request,reply,runner}.ex` — raw HTTP contract, cached conversation construction, validation, continuation, and one repair.

### Operations and release

- `lib/context_bot/operations.ex` — safe workflow/queue/budget health projection.
- `lib/context_bot_web/controllers/health_controller.ex` — existing liveness plus operational summary.
- `secrets.sh`, `test/secrets_test.sh`, `justfile` — allowlisted bot/provider secrets and staged Fly deployment.
- `fly.toml`, `.env.example`, `README.md`, `AGENTS.md` — non-secret live configuration, runbook, and verified commands.
- `test/fixtures/{atproto,anthropic}/**/*.json` — realistic opaque contract fixtures; no real credentials.

---

### Task 1: HTTP, Queue, and Runtime Foundation

**Files:**
- Modify: `mix.exs`
- Modify: `mix.lock`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Modify: `lib/context_bot/application.ex`
- Create: `lib/context_bot/settings.ex`
- Create: `test/context_bot/settings_test.exs`
- Modify: `test/context_bot_web/production_config_test.exs`
- Modify: `test/support/data_case.ex`

**Interfaces:**
- Consumes: process environment and existing Repo/Endpoint configuration.
- Produces: `%ContextBot.Settings{}`; supervised `ContextBot.Finch`; configured `ContextBot.Oban`; test-time manual queues.

- [ ] **Step 1: Add a failing settings test.** Assert defaults for `parent_height: 80`, rate limits `2/5/10/50`, `max_pending: 25`, queue concurrency one, response cap `8_000_000`, storage cap `64_000_000`, and strict rejection of non-integers, invalid booleans, malformed DID allowlists, nonpositive budget, or storage cap not greater than response cap.

Run:

```bash
direnv exec . mix test test/context_bot/settings_test.exs
```

Expected: compilation fails because `ContextBot.Settings` does not exist.

- [ ] **Step 2: Add the runtime dependencies.** Add these exact entries and resolve the lock:

```elixir
{:ecto_sqlite3, "~> 0.24.1"},
{:req, "~> 0.7.1"},
{:finch, "~> 0.23.0"},
{:oban, "~> 2.23.0"}
```

Run `direnv exec . mix deps.get`.

- [ ] **Step 3: Implement `ContextBot.Settings`.** Expose:

```elixir
@spec load(keyword()) :: t()
@spec validate!(t()) :: t()
@spec bot_enabled?(t()) :: boolean()
```

Parse booleans, positive integers, comma-separated exact DIDs, decimal USD through `ContextBot.Money` once Task 8 exists, and fixed URLs. Store only non-secret configuration. Until Task 8, keep `daily_budget_usd` as its validated decimal string.

- [ ] **Step 4: Configure and supervise infrastructure.** Configure:

```elixir
config :context_bot, Oban,
  engine: Oban.Engines.Lite,
  repo: ContextBot.Repo,
  queues: [eligibility: 1, thread: 1, research: 1, reply: 1, maintenance: 1]
```

Use `testing: :manual` in test. Supervise Repo before Finch, Finch before Oban, and bot processes after Oban. Build bot children only when `BOT_ENABLED=true`, so scaffold tests and local Phoenix startup need no live credentials.

- [ ] **Step 5: Add strict production config tests and implementation.** Require `BOT_DID`, `BOT_HANDLE`, `BOT_PDS_URL`, `BOT_APP_PASSWORD`, `ANTHROPIC_API_KEY`, and `ANTHROPIC_DAILY_BUDGET_USD` when enabled. Keep secrets only in application environment consumed by the session/client, never in `%Settings{}` or logs. Add WAL and `busy_timeout: 5_000` to SQLite Repo config.

- [ ] **Step 6: Enable Oban assertions in `DataCase`.** Add `use Oban.Testing, repo: ContextBot.Repo` inside the case template and keep database tests `async: false`.

- [ ] **Step 7: Run the focused and full gates.** Run:

```bash
direnv exec . mix test test/context_bot/settings_test.exs test/context_bot_web/production_config_test.exs
direnv exec . just check
```

Expected: both commands exit 0.

- [ ] **Step 8: Commit.**

```bash
git add mix.exs mix.lock config lib/context_bot/application.ex lib/context_bot/settings.ex test/context_bot/settings_test.exs test/context_bot_web/production_config_test.exs test/support/data_case.ex
git commit -m "chore: add POC runtime foundation"
```

---

### Task 2: Durable Invocation and Oban Persistence

**Files:**
- Create: `priv/repo/migrations/20260729000000_create_poc_workflow.exs`
- Create: `lib/context_bot/workflow/invocation.ex`
- Create: `lib/context_bot/workflow/failure.ex`
- Create: `lib/context_bot/workflow/store.ex`
- Create: `test/context_bot/workflow/store_test.exs`

**Interfaces:**
- Consumes: validated notification maps and Oban job changesets.
- Produces: durable `%Invocation{}` rows and atomic stage/job handoffs.

- [ ] **Step 1: Write failing schema/store tests.** Cover unique `(invocation_uri, notification_cid)`, preservation of both the notification and current CIDs, duplicate strong-reference ingestion without duplicate jobs, the same URI with a new CID as a distinct receipt, explicit statuses, compare-and-transition semantics, and rollback when inserting the next Oban job fails.

Run `direnv exec . mix test test/context_bot/workflow/store_test.exs`; expect missing migration/modules.

- [ ] **Step 2: Create the migration.** Call `Oban.Migration.up(version: 14)`/`down(version: 1)`, then create `invocations` with:

```text
invocation_uri, notification_cid, current_cid, actor_did,
actor_handle, raw_notification, received_at, status, stage,
eligibility_method, eligibility_evidence, admitted_at, defer_until,
raw_thread, canonical_thread, canonical_thread_version,
root_uri, root_cid, anthropic_messages, anthropic_responses,
anthropic_attempt_sequence,
anthropic_usage, selected_reply, reply_validation,
reply_rkey (unique), reply_record, reply_uri, reply_cid,
failure_category, failure_detail, completed_at, timestamps
```

Use `:text` for large strings, `:map` for JSON, UTC microsecond timestamps, a composite unique index on `(invocation_uri, notification_cid)`, foreign/check constraints supported by SQLite, and indexes on `status`, `defer_until`, `actor_did`, and `admitted_at`.

- [ ] **Step 3: Implement the schema and finite failure categories.** Validate the spec's statuses exactly. `Failure.category/1` must return only safe atoms such as `:invalid_input`, `:identity_unavailable`, `:rate_limited`, `:thread_unavailable`, `:provider_auth`, `:provider_budget`, `:provider_response`, `:publication_auth`, and `:publication_conflict`.

- [ ] **Step 4: Implement store primitives.** Expose:

```elixir
@spec receive_mention(map(), DateTime.t(), Ecto.Changeset.t() | nil) ::
        {:ok, Invocation.t(), :inserted | :duplicate}
@spec transition(Invocation.t(), atom(), atom(), map(), Ecto.Changeset.t() | nil) ::
        {:ok, Invocation.t()} | {:error, :stale_stage | Ecto.Changeset.t()}
@spec append_anthropic_response(Invocation.t(), map(), pos_integer()) ::
        {:ok, Invocation.t()} | {:error, :provider_storage_limit}
@spec pending_capacity_available?(pos_integer()) :: boolean()
@spec fail(Invocation.t(), atom(), map()) :: {:ok, Invocation.t()}
```

Use `Ecto.Multi` for state plus next-job insertion and `Repo.transaction(..., mode: :immediate)` for short claims. `append_anthropic_response/3` must count the full accumulated encoded response ledger against the storage cap and preserve each raw body string byte-for-byte after retrieval.

- [ ] **Step 5: Add boundary tests.** Store a raw response at the configured HTTP maximum successfully; reject only when the cumulative provider log exceeds its larger storage cap; prove no parsed projection replaces `raw_body`.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix ecto.migrate
direnv exec . mix test test/context_bot/workflow/store_test.exs
direnv exec . just check
git add priv/repo/migrations/20260729000000_create_poc_workflow.exs lib/context_bot/workflow test/context_bot/workflow
git commit -m "feat: add durable invocation workflow"
```

---

### Task 3: ATProto Value Objects and Frozen Reply Records

**Files:**
- Create: `lib/context_bot/atproto/at_uri.ex`
- Create: `lib/context_bot/atproto/strong_ref.ex`
- Create: `lib/context_bot/atproto/tid.ex`
- Create: `lib/context_bot/atproto/post.ex`
- Create: `test/context_bot/atproto/{at_uri,strong_ref,tid,post}_test.exs`

**Interfaces:**
- Consumes: AT URIs/CIDs, invocation record, root reference, selected text, fixed timestamp.
- Produces: validated strong references, persisted TID rkey, exact `app.bsky.feed.post` map.

- [ ] **Step 1: Add failing value-object tests.** Cover strict `at://<did>/app.bsky.feed.post/<rkey>` parsing, CID/URI presence, lexicographically sortable 13-character lowercase base32 TIDs, and no reuse of the source rkey.

- [ ] **Step 2: Add failing post tests.** Require `reply.parent` to use the fetched current invocation CID and `reply.root` to copy the invocation record's existing root or fall back to parent. Assert the frozen record contains only `$type`, `text`, `createdAt`, and `reply`: no facets, audit suffix, custom record, or generated URL.

- [ ] **Step 3: Implement the pure modules.** Expose:

```elixir
ATURI.parse(binary()) :: {:ok, %{repo: binary(), collection: binary(), rkey: binary()}} | :error
StrongRef.new(binary(), binary()) :: {:ok, map()} | {:error, atom()}
TID.generate(integer()) :: binary()
Post.build(text, parent_ref, root_ref, created_at) :: {:ok, map()} | {:error, atom()}
```

Generate and persist a TID once; retries receive it from SQLite rather than calling `generate/1` again.

- [ ] **Step 4: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/atproto/at_uri_test.exs test/context_bot/atproto/strong_ref_test.exs test/context_bot/atproto/tid_test.exs test/context_bot/atproto/post_test.exs
direnv exec . just check
git add lib/context_bot/atproto test/context_bot/atproto
git commit -m "feat: build deterministic Bluesky reply records"
```

---

### Task 4: Authenticated ATProto Client and Session

**Files:**
- Create: `lib/context_bot/atproto/client.ex`
- Create: `lib/context_bot/atproto/req_client.ex`
- Create: `lib/context_bot/atproto/session.ex`
- Create: `test/context_bot/atproto/req_client_test.exs`
- Create: `test/context_bot/atproto/session_test.exs`
- Create: `test/fixtures/atproto/{session,notifications,thread,profile,identity,record}.json`
- Modify: `config/test.exs`

**Interfaces:**
- Consumes: configured PDS/AppView URLs, bot credentials through `Session`, request arguments.
- Produces: normalized `{:ok, status, headers, body}` or categorized `{:error, reason}` without exposing tokens.

- [ ] **Step 1: Define the behavior and failing contract tests.** The behavior must include `list_notifications/1`, `get_post_thread/2`, `get_profile/2`, `resolve_handle/1`, `resolve_did/1`, `get_record/3`, and `put_record/4`. Use `Req.Test` to assert exact method, path, repeated query keys, headers, and JSON payload.

- [ ] **Step 2: Test session serialization.** Prove one `createSession` authenticates multiple callers, a 401 triggers one serialized `refreshSession`, the returned DID must equal `BOT_DID`, `active: false` stops the session, and tokens never appear in captured logs or any public session API result.

- [ ] **Step 3: Implement the session.** `ContextBot.ATProto.Session` owns access/refresh JWTs only in GenServer state. `access_token/0` returns a token to the concrete client, `refresh/1` replaces the pair atomically, and an invalid refresh falls back to rate-limited create-session rather than a tight loop.

- [ ] **Step 4: Implement the Req client.** Build Req with:

```elixir
finch: [name: ContextBot.Finch, pool_timeout: 5_000,
        receive_timeout: timeout, request_timeout: timeout + 5_000],
retry: false
```

Explicitly send notification query `reasons=mention`, `priority=false`, `limit=100`; preserve opaque cursors, including empty pages with a cursor. Send `depth=0` and configured `parentHeight`. Elder profile reads must use direct `https://api.bsky.app` and `atproto-accept-labelers`.

- [ ] **Step 5: Implement publication calls.** `getRecord` sends repo, collection, and persisted rkey. `putRecord` sends `validate: true`, `swapRecord: nil`, and the frozen record. Classify 401, 429/retry-after, transient 5xx, `RecordNotFound`, `InvalidSwap`, timeout, and permanent 4xx separately.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/atproto/req_client_test.exs test/context_bot/atproto/session_test.exs
direnv exec . just check
git add config/test.exs lib/context_bot/atproto test/context_bot/atproto test/fixtures/atproto
git commit -m "feat: add authenticated ATProto client"
```

---

### Task 5: Direct-Mention Polling and Idempotent Receipt

**Files:**
- Create: `lib/context_bot/mentions/validator.ex`
- Create: `lib/context_bot/mentions/poller.ex`
- Create: `test/context_bot/mentions/validator_test.exs`
- Create: `test/context_bot/mentions/poller_test.exs`

**Interfaces:**
- Consumes: ATProto notification pages and bot DID.
- Produces: validated receipt maps and at most one eligibility job per source `(URI, CID)` strong reference.

- [ ] **Step 1: Add failing validator tests.** Accept only reason `mention`, collection/type `app.bsky.feed.post`, non-bot author, URI repository equal to author DID, nonempty CID, and an explicit rich-text mention facet whose feature DID equals `BOT_DID`. Reject text-only `@handle` matches.

- [ ] **Step 2: Implement `Validator.validate/2`.** Return `{:ok, %{uri:, cid:, actor_did:, actor_handle:, raw:}}` or `{:error, safe_reason}` without normalizing away the raw notification.

- [ ] **Step 3: Add failing poller tests.** Cover non-overlapping ticks, newest-page restart on every poll, walking backward through an empty filtered page with a cursor, stopping at durable known `(URI, CID)` strong references or the page cap, reversing newly discovered receipts to enqueue oldest-first, capacity deferral, and no `updateSeen` call.

- [ ] **Step 4: Implement the poller.** Use a GenServer `Process.send_after` loop that schedules the next tick only after the current drain returns. Insert every valid unseen receipt; call `Store.pending_capacity_available?/1` before attaching the eligibility job, otherwise store `deferred_capacity`. Never persist the backward cursor as a forward checkpoint. Task 6's admission transaction rechecks capacity before accepting work, so this ingestion check is backpressure rather than authorization.

- [ ] **Step 5: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/mentions/validator_test.exs test/context_bot/mentions/poller_test.exs
direnv exec . just check
git add lib/context_bot/mentions test/context_bot/mentions
git commit -m "feat: ingest direct Bluesky mentions"
```

---

### Task 6: Eligibility and Admission Limits

**Files:**
- Create: `lib/context_bot/eligibility.ex`
- Create: `lib/context_bot/admission.ex`
- Create: `lib/context_bot/workers/eligibility_worker.ex`
- Create: `test/context_bot/eligibility_test.exs`
- Create: `test/context_bot/admission_test.exs`
- Create: `test/context_bot/workers/eligibility_worker_test.exs`

**Interfaces:**
- Consumes: actor DID/observed handle, current clock, ATProto client, invocation counts.
- Produces: `{:eligible, method, evidence}`, `:ineligible`, retryable lookup error, or atomically admitted/deferred invocation.

- [ ] **Step 1: Add failing pure eligibility tests.** Assert this interface:

```elixir
check(actor_did, observed_handle, now, settings, client) ::
  {:eligible, :operator_allowlist | :bluesky_elder | :bsky_team, map()}
  | :ineligible
  | {:error, atom()}
```

Test exact Skywatch source DID, actor URI, `bluesky-elder` value, absent/false `neg`, absent/future `exp`, and required `atproto-content-labelers` response header. A missing label is ineligible only when the header proves the custom labeler participated; a missing header is retryable/unavailable.

- [ ] **Step 2: Test and implement team verification.** Normalize lowercase, accept only exact `bsky.team` or `.bsky.team` boundary, require forward handle resolution to actor DID, then require a supported DID document with matching `id` and first valid `at://` claim equal to the handle. Reject `notbsky.team`, stale forward-only records, unsupported DID methods, and lookup failures closed.

- [ ] **Step 3: Add failing admission transaction tests.** At a fixed clock, cover 2 actor/hour, 5 actor/24h, 10 global/hour, 50 global/24h, 25 pending, boundary timestamps, concurrent claims, and allowlisted actors not bypassing limits.

- [ ] **Step 4: Implement admission.** Expose:

```elixir
capacity_available?(Settings.t()) :: boolean()
admit(Invocation.t(), DateTime.t(), Settings.t(), Oban.Job.changeset()) ::
  {:ok, Invocation.t()} | {:deferred, :rate | :capacity, Invocation.t()}
```

Use a short `mode: :immediate` transaction, count `admitted_at` windows and pending statuses, then commit `capturing_thread` and its job together. Set `defer_until` to the earliest relevant rolling-window expiry.

- [ ] **Step 5: Implement the worker.** Claim `received`, reconsidered `deferred_rate`, or its own resumable `checking_eligibility` state; store method/evidence without raw profile payloads or tokens; mark ineligible terminally; return retry on identity/label outage; never enqueue thread for ineligible/deferred work.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/eligibility_test.exs test/context_bot/admission_test.exs test/context_bot/workers/eligibility_worker_test.exs
direnv exec . just check
git add lib/context_bot/eligibility.ex lib/context_bot/admission.ex lib/context_bot/workers/eligibility_worker.ex test/context_bot
git commit -m "feat: enforce mention eligibility and admission"
```

---

### Task 7: Ancestor-Only Thread Capture

**Files:**
- Create: `lib/context_bot/thread/canonicalizer.ex`
- Create: `lib/context_bot/workers/thread_worker.ex`
- Create: `test/context_bot/thread/canonicalizer_test.exs`
- Create: `test/context_bot/workers/thread_worker_test.exs`
- Create: `test/fixtures/atproto/thread_ancestors.json`
- Create: `test/fixtures/atproto/thread_blocked_parent.json`
- Create: `test/fixtures/atproto/thread_edited_cid.json`

**Interfaces:**
- Consumes: `getPostThread` union and invocation receipt.
- Produces: bounded raw snapshot, versioned root-to-invocation text, root/parent strong refs, research job.

- [ ] **Step 1: Add failing canonicalizer tests.** Use nested `.parent` unions and a fixture containing a tempting descendant in `.replies`. Assert root-to-parent-to-invocation order, zero descendant text, explicit `[blocked ancestor]`/`[unavailable ancestor]` placeholders, truncation marker at parent cap, external-link title/URI, quoted-post URI only, and no media interpretation.

- [ ] **Step 2: Implement `Canonicalizer.build/2`.** Return:

```elixir
{:ok, %{version: 1, text: binary(), parent: strong_ref(), root: strong_ref(), current_cid: binary()}}
| {:error, :target_unavailable | :invalid_thread}
```

Traverse only `parent`; ignore `replies` even when returned by a faulty fixture. For an edited CID, revalidate that the current target record still directly mentions the bot and freeze the current CID as reply parent.

- [ ] **Step 3: Add failing worker handoff tests.** Prove the request sends `depth=0`, raw/canonical thread state and the research job become visible in the same commit, Anthropic cannot execute before that commit, and a failed database commit exposes neither state nor job.

- [ ] **Step 4: Implement the worker.** Claim `capturing_thread` as both the initial and resumable in-progress state. Fetch outside transactions with response-size/timeout enforcement, then atomically set `thread_ready`, persist snapshot/text/refs/current CID, and enqueue research. Retry transient failures with capped backoff; terminal target unavailability calls `Store.fail/3` and publishes nothing.

- [ ] **Step 5: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/thread/canonicalizer_test.exs test/context_bot/workers/thread_worker_test.exs
direnv exec . just check
git add lib/context_bot/thread lib/context_bot/workers/thread_worker.ex test/context_bot/thread test/context_bot/workers/thread_worker_test.exs test/fixtures/atproto/thread_*.json
git commit -m "feat: capture ancestor-only thread context"
```

---

### Task 8: Integer Pricing and Atomic Daily Budget

**Files:**
- Create: `priv/repo/migrations/20260729001000_create_api_budget_entries.exs`
- Create: `lib/context_bot/money.ex`
- Create: `lib/context_bot/research/budget_entry.ex`
- Create: `lib/context_bot/research/pricing.ex`
- Create: `lib/context_bot/research/budget.ex`
- Create: `test/context_bot/money_test.exs`
- Create: `test/context_bot/research/pricing_test.exs`
- Create: `test/context_bot/research/budget_test.exs`

**Interfaces:**
- Consumes: decimal USD config, UTC clock, invocation/kind, Anthropic usage.
- Produces: atomic reservation/settlement rows and remaining daily microdollars.

- [ ] **Step 1: Add failing money/pricing tests.** Parse decimal USD without float conversion and reject more than six fractional places. For pricing version `sonnet-5-2026-07-28`, calculate uncached input at 2 microdollars/token, 5-minute writes at 2.5, one-hour writes at 4, cache reads at 0.2, output at 10, and successful web search at 10,000 microdollars. Use rational integer arithmetic and explicit ceiling; do not double-count aggregate cache writes or thinking tokens.

- [ ] **Step 2: Create `priv/repo/migrations/20260729001000_create_api_budget_entries.exs`.** Fields: unique `attempt_key`, `invocation_id` FK, `budget_date`, `kind`, `reserved_microdollars`, `settled_microdollars`, `state`, `usage`, `pricing_version`, `sent_at`, `response_recorded_at`, and UTC timestamps. States are `reserved`, `sent`, `settled`, and `indeterminate`. Index date/state and invocation.

- [ ] **Step 3: Add failing budget tests.** Assert:

```elixir
reserve_next(Invocation.t(), kind, now, amount, daily_limit) ::
  {:ok, BudgetEntry.t()} | {:error, :daily_budget_exhausted}
mark_sent(BudgetEntry.t(), DateTime.t()) :: {:ok, BudgetEntry.t()}
settle(BudgetEntry.t(), usage, Pricing.t()) :: {:ok, BudgetEntry.t()}
mark_indeterminate(BudgetEntry.t()) :: {:ok, BudgetEntry.t()}
```

Cover monotonic attempt-key allocation, concurrent reservations, settled entries counting settled value, reserved/sent/indeterminate entries counting full reservation, unsafe usage retaining full reservation, and UTC rollover. `reserve_next/5` must increment `invocations.anthropic_attempt_sequence` and insert `invocation-<id>-attempt-<sequence>-<kind>` in the same immediate transaction.

- [ ] **Step 4: Implement with immediate SQLite transactions.** Reserve before HTTP, never after. Persist `sent` immediately before handing bytes to Finch. On recovery, a `sent` entry with no recorded response is indeterminate because the provider may have billed it; any replay requires a newly sequenced reservation. A merely `reserved` entry may be reused because it was never exposed. Settlement must never increase beyond the reservation; if calculated maximum exposure can exceed reservation, reject configuration at startup.

- [ ] **Step 5: Wire validated microdollar settings.** Replace Task 1's temporary decimal fields with parsed microdollars and validate research/continuation/repair/retry reservations against the daily limit and configured request maxima.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/money_test.exs test/context_bot/research/pricing_test.exs test/context_bot/research/budget_test.exs test/context_bot/settings_test.exs
direnv exec . just check
git add priv/repo/migrations lib/context_bot/money.ex lib/context_bot/settings.ex lib/context_bot/research test/context_bot
git commit -m "feat: enforce daily Anthropic budget"
```

---

### Task 9: Raw Anthropic HTTP Client and Response Limits

**Files:**
- Create: `lib/context_bot/research/client.ex`
- Create: `lib/context_bot/research/anthropic_client.ex`
- Create: `lib/context_bot/http/body_limit.ex`
- Create: `test/context_bot/research/anthropic_client_test.exs`
- Create: `test/context_bot/http/body_limit_test.exs`
- Create: `test/fixtures/anthropic/{success,pause,error,refusal}.json`
- Modify: `config/test.exs`

**Interfaces:**
- Consumes: JSON request map and non-secret request metadata.
- Produces: exact raw response envelope; never performs workflow persistence or automatic retries.

- [ ] **Step 1: Add failing body-limit tests.** Accept exactly `ANTHROPIC_RESPONSE_MAX_BYTES`, reject the next byte before JSON decoding, and ensure chunked and content-length responses use the same bound.

- [ ] **Step 2: Define the client behavior.** Use:

```elixir
send_message(request_map, attempt_metadata) ::
  {:ok, %{status: pos_integer(), headers: map(), raw_body: binary(),
          received_at: DateTime.t(), duration_ms: non_neg_integer()}}
  | {:error, :response_too_large | :timeout | :transport}
```

The behavior returns raw bytes only. Decoding and interpretation happen after `Store.append_anthropic_response/3` in Task 11.

- [ ] **Step 3: Add failing Req contract tests.** Assert POST `/v1/messages`, `x-api-key`, `anthropic-version: 2023-06-01`, JSON content type, non-streaming request, `retry: false`, and redaction from errors/logs. Preserve only safe response headers: `request-id`, `retry-after`, rate-limit headers, and content type.

- [ ] **Step 4: Implement the concrete client.** Use named Finch and a body-limiting Req response step. Never enable Req's retry layer because the workflow owns reservations and attempt identities. Map 429/5xx as returned HTTP envelopes rather than transport errors; return ambiguous timeout distinctly so the caller can retain its reservation.

- [ ] **Step 5: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/http/body_limit_test.exs test/context_bot/research/anthropic_client_test.exs
direnv exec . just check
git add config/test.exs lib/context_bot/http lib/context_bot/research/client.ex lib/context_bot/research/anthropic_client.ex test/context_bot/http test/context_bot/research/anthropic_client_test.exs test/fixtures/anthropic
git commit -m "feat: add bounded Anthropic HTTP client"
```

---

### Task 10: Cached Claude Request and Reply Validation

**Files:**
- Create: `lib/context_bot/research/request.ex`
- Create: `lib/context_bot/research/reply.ex`
- Create: `test/context_bot/research/request_test.exs`
- Create: `test/context_bot/research/reply_test.exs`

**Interfaces:**
- Consumes: versioned canonical thread and full prior assistant blocks.
- Produces: exact Messages request maps and a validated reply text.

- [ ] **Step 1: Add failing initial-request tests.** Assert model `claude-sonnet-5` (configurable), `max_tokens`, `stream: false`, top-level `cache_control: %{type: "ephemeral"}`, adaptive thinking with omitted display, high effort, auto tool choice, and no sampling fields. Assert dated tools `web_search_20260318` and `web_fetch_20260318` with `allowed_callers: ["direct"]`, `response_inclusion: "full"`, fetch `use_cache: false`, citations enabled, and configured use/content caps.

- [ ] **Step 2: Add failing continuation/repair tests.** `pause_turn` must append the complete assistant `content` deeply unchanged, including unknown blocks, signatures, encrypted fields, caller metadata, and unresolved server calls. A repair must preserve byte-equivalent system, tools, settings, original messages, and completed assistant content, then append one `LENGTH_REPAIR` user turn; only `max_tokens` may differ.

- [ ] **Step 3: Implement `Request.initial/2`, `continue/3`, and `repair/3`.** Keep the versioned prompt in the module as a single complete constant. It must instruct ancestor-context use, research of unstable claims, primary-source preference, fact/value separation, uncertainty, prompt-injection resistance, and return-only-reply output with at most 300 graphemes and no audit suffix.

- [ ] **Step 4: Add failing reply tests.** Concatenate final model-authored text blocks in order. Accept nonempty `end_turn` output at exactly 300 graphemes and 3,000 UTF-8 bytes. Reject empty, unexpected/pending tool use, refusal, `max_tokens`, context-window exhaustion, other stop reasons, 301 graphemes, or 3,001 bytes. Exercise combining marks, emoji ZWJ sequences, and multibyte text with `String.length/1` plus `byte_size/1`. Never truncate.

- [ ] **Step 5: Implement `Reply.select/2`.** Return:

```elixir
{:ok, text} | {:repairable, text, reasons} | {:error, terminal_reason}
```

Only normally completed nonempty text that fails shape/length is repairable. Incomplete/refusal/tool states are terminal.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/research/request_test.exs test/context_bot/research/reply_test.exs
direnv exec . just check
git add lib/context_bot/research/request.ex lib/context_bot/research/reply.ex test/context_bot/research
git commit -m "feat: construct cached Claude conversations"
```

---

### Task 11: Budgeted Research Runner and Durable Research Worker

**Files:**
- Create: `lib/context_bot/research/runner.ex`
- Create: `lib/context_bot/workers/research_worker.ex`
- Create: `test/context_bot/research/runner_test.exs`
- Create: `test/context_bot/workers/research_worker_test.exs`
- Create: `test/fixtures/anthropic/{tool_success,pause_then_success,repair_success,unknown_blocks}.json`

**Interfaces:**
- Consumes: `thread_ready` invocation, budget, Anthropic client, bounded retry policy.
- Produces: `reply_ready` invocation with complete response ledger, usage, selected text, frozen post/rkey, and reply job.

- [ ] **Step 1: Add failing persistence-order tests.** For every HTTP envelope—200, 429, 500, malformed JSON, pause, final, repair—assert its complete `raw_body` is in SQLite before the runner decodes or decides the next action. A forced persistence failure must stop without continuation, repair, retry, or reply.

- [ ] **Step 2: Add failing budget/retry and crash-window tests.** Assert a unique reservation exists before every initial, continuation, repair, and transport retry call. Inject crashes after reservation, after the persisted `sent` marker, after Finch returns but before raw-response persistence, and after persistence but before settlement. A reserved-but-unsent attempt is reusable; a sent attempt without a response becomes indeterminate and replay gets a new reservation/key; a persisted response resumes decoding/settlement without another POST. A 429/5xx honors parsed `retry-after` and uses a new `:retry` attempt key; an ambiguous POST timeout may retry only once and both reservations count. Auth/permanent 4xx do not spin.

- [ ] **Step 3: Add failing continuation tests.** Repeat `pause_turn` within a configured aggregate cap, append opaque assistant content unchanged, retain each full raw response in order, and aggregate tool/usage counts. Exceeding continuation or tool-use caps fails silently.

- [ ] **Step 4: Add failing one-repair tests.** A valid primary enqueues no repair. A normally completed shape/length failure sends one cached repair. Repair tool use, empty response, refusal, truncation, second invalid output, or cache miss behavior must never cause a second repair. A cache miss remains valid and is recorded in usage.

- [ ] **Step 5: Implement `Runner.run/2`.** Sequence each attempt as: reserve a monotonically sequenced key, persist `sent`, send, append the raw envelope tagged with that attempt key and mark `response_recorded_at`, decode, settle/retain reservation, classify. At entry, reconcile unfinished ledger entries before deciding whether any POST is allowed. Never derive attempt identity from response count because a process can die before a response is recorded.

- [ ] **Step 6: Implement the worker and atomic frozen handoff.** Claim `thread_ready`, eligible `deferred_budget`, or its own resumable `researching` state. If budget is unavailable, set `deferred_budget` through next UTC rollover. On valid text, generate a TID and fixed `createdAt`, build the exact reply record, then atomically persist messages/responses/usage/text/validation/rkey/record and enqueue `ReplyWorker`. The post must be queryable before any PDS write.

- [ ] **Step 7: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs
direnv exec . just check
git add lib/context_bot/research/runner.ex lib/context_bot/workers/research_worker.ex test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs test/fixtures/anthropic
git commit -m "feat: run durable budgeted Claude research"
```

---

### Task 12: Exactly-Once Reply Publication

**Files:**
- Create: `lib/context_bot/workers/reply_worker.ex`
- Create: `test/context_bot/workers/reply_worker_test.exs`

**Interfaces:**
- Consumes: `reply_ready` invocation with frozen rkey/record and ATProto client.
- Produces: `complete` with remote URI/CID, retryable publication state, or terminal conflict.

- [ ] **Step 1: Add failing reconciliation tests.** Cover GET missing then successful PUT; GET exact match without PUT; GET mismatched record terminal; timeout/`InvalidSwap` then matching GET; timeout then missing GET and bounded retry with the same rkey/record; auth failure waiting for operator; and repeated jobs producing exactly one PUT-visible record.

- [ ] **Step 2: Define structural equality.** Compare the returned repository, collection, rkey, and decoded record against the frozen intent. Accept the PDS-assigned CID only after equality. Ignore no record fields: a remote extra or changed field is a conflict and must never be overwritten.

- [ ] **Step 3: Implement the worker.** Claim either `reply_ready` or its own resumable `publishing` state, transition only the former to `publishing`, GET before PUT, PUT with explicit create-only `swapRecord: nil`, reconcile ambiguous results, then store `reply_uri`, `reply_cid`, `complete`, and `completed_at`. All retries reuse the persisted rkey/record. Terminal errors publish no fallback post.

- [ ] **Step 4: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/workers/reply_worker_test.exs
direnv exec . just check
git add lib/context_bot/workers/reply_worker.ex test/context_bot/workers/reply_worker_test.exs
git commit -m "feat: publish exactly one Bluesky reply"
```

---

### Task 13: Deferred Work, Recovery, and Safe Operations

**Files:**
- Modify: `config/config.exs`
- Create: `lib/context_bot/workers/deferred_worker.ex`
- Create: `lib/context_bot/operations.ex`
- Create: `test/context_bot/workers/deferred_worker_test.exs`
- Create: `test/context_bot/operations_test.exs`
- Modify: `lib/context_bot_web/controllers/health_controller.ex`
- Modify: `test/context_bot_web/controllers/health_controller_test.exs`

**Interfaces:**
- Consumes: deferred invocations, current UTC time, limits, queue state.
- Produces: oldest-first reconsideration jobs and credential-free operational health.

- [ ] **Step 1: Add failing deferred tests.** Seed mixed `deferred_capacity`, `deferred_rate`, and `deferred_budget` rows. Assert oldest-first order, due-time filtering, capacity recheck, current eligibility recheck for rate deferrals, budget retry only after UTC rollover, and no duplicate jobs across repeated cron runs.

- [ ] **Step 2: Implement `DeferredWorker` and schedule it.** Process a configured small batch under a short immediate claim transaction, then enqueue outside any external-call transaction. Capacity returns to eligibility; rate returns to eligibility so current identity is checked; budget returns directly to research only if the earlier eligibility evidence is still within the same accepted workflow and all admission windows remain valid. Add `{Oban.Plugins.Cron, crontab: [{"* * * * *", ContextBot.Workers.DeferredWorker}]}` to the configured Oban plugins only after the worker exists.

- [ ] **Step 3: Add restart-recovery tests.** For every committed stage (`received`, `capturing_thread`, `thread_ready`, `researching`, `reply_ready`, `publishing`), simulate a missing job and assert the maintenance pass enqueues only the idempotent worker needed to resume it. Do not revive terminal `ineligible`, `failed`, or `complete` rows.

- [ ] **Step 4: Add failing health/log tests.** Health JSON may expose bot enabled/session state, queue counts, deferred counts, failure counts by safe category, today's reserved/settled budget, and oldest pending age. Assert it contains no notification/thread/provider bodies, handles, DIDs, URI text, tokens, headers, or secret values. Keep `/health` HTTP 200 as process liveness even when provider dependencies are degraded.

- [ ] **Step 5: Implement safe operations and structured logging.** Log invocation database ID, stage, attempt kind/index, safe status code, duration, and failure category only. Explicitly avoid inspecting request/client/session structs.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/workers/deferred_worker_test.exs test/context_bot/operations_test.exs test/context_bot_web/controllers/health_controller_test.exs
direnv exec . just check
git add config/config.exs lib/context_bot/workers/deferred_worker.ex lib/context_bot/operations.ex lib/context_bot_web/controllers/health_controller.ex test/context_bot/workers/deferred_worker_test.exs test/context_bot/operations_test.exs test/context_bot_web/controllers/health_controller_test.exs
git commit -m "feat: recover deferred context bot work"
```

---

### Task 14: End-to-End Mocked Workflow

**Files:**
- Create: `test/context_bot/poc_workflow_test.exs`
- Create: `test/support/fake_clock.ex`
- Create: `test/support/poc_fixture.ex`

**Interfaces:**
- Consumes: realistic ATProto/Anthropic fixtures through Req.Test and manual Oban queues.
- Produces: executable acceptance proof for the complete durable pipeline.

- [ ] **Step 1: Add the eligible happy-path test.** Poll one public direct mention beneath two ancestors plus one descendant fixture, drain eligibility/thread/research/reply queues, and assert one PDS record. Assert the model request contains the ancestors and invocation, not the descendant; thread state predates Anthropic response state; reply record predates PUT; final reply has correct root/parent and limits.

- [ ] **Step 2: Add authorization/limit tests.** For ineligible, actor-rate, global-rate, pending-capacity, and exhausted-budget cases, assert no unauthorized downstream HTTP call. Add allowlist, valid Elder, valid team, invalid Elder header, and stale team identity scenarios.

- [ ] **Step 3: Add idempotency/restart tests.** Repeat polls and every job; restart the session/poller between committed stages; simulate one ambiguous Anthropic POST and one ambiguous PDS PUT. Assert complete response retention, all charged reservations, and exactly one public reply.

- [ ] **Step 4: Add failure-silence tests.** Refusal, malformed provider JSON, oversized response, unavailable target, publication conflict, and exhausted retries must set categorized state and create no error reply.

- [ ] **Step 5: Run the acceptance test and full gate.**

```bash
direnv exec . mix test test/context_bot/poc_workflow_test.exs --trace
direnv exec . just check
```

Expected: all workflow scenarios pass and the full gate exits 0.

- [ ] **Step 6: Commit.**

```bash
git add test/context_bot/poc_workflow_test.exs test/support/fake_clock.ex test/support/poc_fixture.ex
git commit -m "test: verify context bot POC workflow"
```

---

### Task 15: Secrets, Fly Configuration, and Live Runbook

**Files:**
- Modify: `secrets.sh`
- Modify: `test/secrets_test.sh`
- Modify: `justfile`
- Modify: `fly.toml`
- Create: `.env.example`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: allowlisted Bitwarden custom fields and non-secret environment values.
- Produces: reproducible local startup, staged Fly secrets, deployment command, and operator smoke-test procedure.

- [ ] **Step 1: Extend failing shell tests.** Require `BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY` custom fields in addition to `FLY_API_TOKEN` and `SECRET_KEY_BASE`; verify partial payload cleanup, ignored fields, no values in output, and exported names only.

Run `direnv exec . bash test/secrets_test.sh`; expect failure until the allowlist changes.

- [ ] **Step 2: Extend `secrets.sh` and deploy.** Keep its existing all-or-nothing cleanup. `just deploy` must stage `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY`, authenticate Fly through `FLY_API_TOKEN`, then deploy. Never echo values.

- [ ] **Step 3: Add non-secret Fly configuration.** Add bot identity/PDS, direct AppView, polling/thread/tool/rate settings, provider model/version, response/storage caps, daily budget, reservations, and pricing version to `[env]`. Use the actual public bot DID/handle only when supplied by the operator. Until then document those required values and the `BOT_ENABLED=true` activation step in `.env.example`, and leave `BOT_ENABLED=false` in committed Fly config so an accidental deploy cannot poll the wrong account.

- [ ] **Step 4: Write the operator runbook.** Document Devbox startup, database migration, required Bitwarden field names, `just dev`, safe health inspection, queue/state SQLite queries, explicit deploy command, and rollback. Document two manual tests: eligible mention receives exactly one correctly rooted reply; ineligible mention causes no Claude request or reply.

- [ ] **Step 5: Update agent guidance.** Replace the foundation-only caveat with the concrete POC modules and invariants, while retaining isolated worktree instructions. State that live deploy/smoke actions always require explicit authorization.

- [ ] **Step 6: Verify without deploying.**

```bash
direnv exec . bash test/secrets_test.sh
direnv exec . just check
direnv exec . just docker-build
git diff --check
```

Start the image with `BOT_ENABLED=false` and a temporary mounted database, then assert `GET /health` returns 200. Do not call Fly or Bluesky in this step.

- [ ] **Step 7: Commit.**

```bash
git add secrets.sh test/secrets_test.sh justfile fly.toml .env.example README.md AGENTS.md
git commit -m "docs: add POC deployment runbook"
```

---

## Final Verification and Authorized Live Smoke Test

- [ ] **Step 1: Prove the branch is clean and reproducible.**

```bash
direnv exec . just setup
direnv exec . just check
direnv exec . just docker-build
git diff --check
git status --short
```

Expected: setup/check/build succeed, diff check is empty, and status has no uncommitted files.

- [ ] **Step 2: Review non-goals mechanically.**

```bash
rg -n "org\.social-protocols\.contextbot|audit link|IPFS|LiveView" lib priv test
rg -n "depth" lib/context_bot
rg -n "updateSeen" lib test
```

Expected: no custom/audit/IPFS/UI implementation; thread request explicitly uses `depth=0`; no notification `updateSeen` call.

- [ ] **Step 3: Inspect migration and secrets.** Confirm no credential-shaped column exists, provider raw bodies are bounded above HTTP max, and only allowlisted Bitwarden names are loaded.

- [ ] **Step 4: Request explicit authorization for external effects.** Only after approval, populate the real bot DID/handle, unlock Bitwarden, run `direnv exec . just deploy`, and observe Fly health/logs without printing secrets or content bodies.

- [ ] **Step 5: Run the authorized live smoke test.** From an eligible public account, mention the bot beneath an ancestor chain; confirm SQLite stages progress, the one reply appears below the invocation with the correct root, and no descendant was supplied to Claude. Repeat the notification poll and confirm no duplicate reply. From an ineligible account, confirm no thread, Claude, or reply call.

- [ ] **Step 6: Integrate only after the live outcome is accepted.** Use the finishing-a-development-branch workflow, rebase/fast-forward or cherry-pick to keep history linear, and integrate `codex/context-bot-mvp` into `main` as the user requested. Do not create a merge commit.
