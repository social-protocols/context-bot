# Image Support and Video Fail-Closed Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist and send bounded Bluesky images to Anthropic while routing any video-containing
thread to a deterministic, provider-free reply through the existing durable publication path.

**Architecture:** Canonical thread v2 carries deterministic text plus a bounded `canonical_media`
list. `Research.Request` converts supported images into Anthropic URL image blocks. The thread worker
handles typed media dispositions before research, and a shared reply-intent builder freezes both
model-produced and deterministic public replies with the same ATProto invariants.

**Tech Stack:** Elixir 1.20, Phoenix/Ecto, SQLite, Oban, ExUnit, Req, Anthropic Messages API, ATProto

---

## Task 1: Add Durable Canonical Media Storage

**Files:**

- Create: `priv/repo/migrations/20260824000000_add_canonical_media.exs`
- Modify: `lib/context_bot/workflow/invocation.ex`
- Test: `test/context_bot/workflow/invocation_test.exs`

### Step 1: Write the failing schema test

Add a test that inserts an invocation with a JSON list of canonical image descriptors and asserts
that a repository reload preserves it exactly. Assert that an omitted value remains an empty list or
`nil` according to the migration default selected for legacy rows.

### Step 2: Run the focused test and verify it fails

Run:

```bash
direnv exec . just test test/context_bot/workflow/invocation_test.exs
```

Expected: failure because `canonical_media` is not a castable schema field or database column.

### Step 3: Implement the migration and schema field

Add a nullable JSON/map column suitable for a list, expose `canonical_media` as
`{:array, :map}` on `Invocation`, and include it in transition fields. Preserve legacy rows without
backfilling or rewriting frozen Anthropic requests.

### Step 4: Run the focused test and migration checks

Run:

```bash
direnv exec . just test test/context_bot/workflow/invocation_test.exs
```

Expected: pass.

## Task 2: Canonicalize Images and Detect Unsupported Media

**Files:**

- Modify: `lib/context_bot/thread/canonicalizer.ex`
- Modify: `test/context_bot/thread/canonicalizer_test.exs`
- Modify: `test/fixtures/atproto/thread_ancestors.json`
- Create: `test/fixtures/atproto/thread_video.json`

### Step 1: Write failing image behavior tests

Change the existing image fixture to use realistic `https://cdn.bsky.app` full-size URLs. Assert
that public and dry-run canonicalization now return version 2, persist one ordered image descriptor,
render a numbered image marker and bounded alt text, and still exclude descendants and quoted-record
bodies.

Add tests for multiple images across root-to-invocation order and images nested under
`app.bsky.embed.recordWithMedia#view`.

### Step 2: Run the focused tests and verify the intended failures

Run:

```bash
direnv exec . just test test/context_bot/thread/canonicalizer_test.exs
```

Expected: assertions fail because canonicalization still returns v1 and discards images.

### Step 3: Write failing validation and disposition tests

Add table-driven tests for malformed or untrusted image URLs: non-HTTPS, alternate host, userinfo,
fragment, non-default port, missing full-size URL, invalid enclosing post, overlong URL, and overlong
alt text. Assert malformed embeds return `{:error, :invalid_thread}`.

Add tests that direct and `recordWithMedia` video embeds return a typed
`{:unsupported_media, result}` with `:video`, and that five images return the corresponding
`:image_limit_exceeded` result. Assert video takes precedence when both are present.

### Step 4: Implement one deterministic media scan

Refactor rendering so each available post is scanned once in root-to-invocation order. Keep external
and quoted-post text behavior, number accepted images globally, validate exact CDN URLs, cap counts
and serialized fields, and return one of:

- `{:ok, canonical_v2}`;
- `{:unsupported_media, canonical_v2_with_disposition}`; or
- `{:error, :invalid_thread | :target_unavailable}`.

Do not traverse descendants or recursively inspect quoted records.

### Step 5: Run the canonicalizer tests

Run:

```bash
direnv exec . just test test/context_bot/thread/canonicalizer_test.exs
```

Expected: pass.

## Task 3: Build and Freeze Anthropic Image Requests

**Files:**

- Modify: `lib/context_bot/research/request.ex`
- Modify: `lib/context_bot/research/runner.ex`
- Modify: `test/context_bot/research/request_test.exs`
- Modify: `test/context_bot/research/runner_test.exs`
- Modify: `test/context_bot/dry_run_workflow_test.exs`
- Modify: `test/context_bot/poc_workflow_test.exs`
- Modify: `test/context_bot/live_run_workflow_test.exs`

### Step 1: Write failing request-construction tests

Add version 2 cases asserting that URL image blocks appear before one transcript text block, markers
remain in the transcript, text-only v2 still uses a content list, and version 1 string content remains
unchanged for legacy replay. Assert the system prompt describes untrusted image/alt content,
observed-versus-captioned claims, provenance research, synthetic-origin uncertainty, and refusal to
infer AI generation from appearance alone.

### Step 2: Run the request tests and verify failure

Run:

```bash
direnv exec . just test test/context_bot/research/request_test.exs
```

Expected: v2 clauses are missing and the prompt lacks the image safety contract.

### Step 3: Implement v2 request construction

Keep the existing top-level request and web-tool configuration cache-compatible. Build only the
first user message differently for v2: ordered Anthropic URL image blocks followed by a text block.
Retain the v1 clause for old rows.

### Step 4: Write and run failing runner checkpoint tests

Add a runner test with `canonical_thread_version: "2"` and `canonical_media` descriptors. Assert the
exact v2 content list is committed to `anthropic_messages` before the fake client observes it, and a
pre-existing request is replayed unchanged.

Run:

```bash
direnv exec . just test test/context_bot/research/runner_test.exs
```

Expected before implementation: the runner hard-codes version 1 and omits media.

### Step 5: Pass persisted canonical version and media to `Request.initial/2`

Parse only supported canonical version strings, pass the stored media list, and fail safely for an
unknown or malformed canonical snapshot. Never rebuild a non-nil `anthropic_messages` request.

### Step 6: Update workflow expectations and run the research suite

Update end-to-end fake-provider assertions from string content to the v2 content list while retaining
explicit legacy-v1 coverage.

Run:

```bash
direnv exec . just test test/context_bot/research/request_test.exs test/context_bot/research/runner_test.exs test/context_bot/dry_run_workflow_test.exs test/context_bot/poc_workflow_test.exs test/context_bot/live_run_workflow_test.exs
```

Expected: pass.

## Task 4: Share Reply Intent Construction

**Files:**

- Create: `lib/context_bot/reply/intent.ex`
- Create: `test/context_bot/reply/intent_test.exs`
- Modify: `lib/context_bot/workers/research_worker.ex`
- Modify: `test/context_bot/workers/research_worker_test.exs`

### Step 1: Write failing pure intent tests

Cover a valid root reply, a nil root falling back through `Post.build/4`, invalid bot DID, invalid
parent/current CID, invalid root reference, and deterministic injected TID output. The returned value
must include `reply_repo`, `reply_rkey`, and the exact reply record without database effects.

### Step 2: Run the focused test and verify it fails

Run:

```bash
direnv exec . just test test/context_bot/reply/intent_test.exs
```

Expected: module is undefined.

### Step 3: Extract the shared intent builder

Move repository validation, parent/root selection, `Post.build/4`, and TID allocation out of
`ResearchWorker`. Accept the current invocation, reply text, bot DID, timestamp, and injectable TID
generator; return typed errors without persistence.

### Step 4: Refactor `ResearchWorker` and run its tests

Inject the intent module or function through worker dependencies if needed for focused tests. Keep
dry-run behavior unchanged and keep the transition guarded by the research claim token.

Run:

```bash
direnv exec . just test test/context_bot/reply/intent_test.exs test/context_bot/workers/research_worker_test.exs
```

Expected: pass with all existing publication invariants intact.

## Task 5: Route Capability Replies in the Thread Worker

**Files:**

- Modify: `lib/context_bot/workers/thread_worker.ex`
- Modify: `test/context_bot/workers/thread_worker_test.exs`
- Modify: `test/context_bot/dry_run_workflow_test.exs`
- Modify: `test/context_bot/live_run_workflow_test.exs`

### Step 1: Write failing dry-run capability tests

For a video response, assert one thread fetch followed by direct `complete`, the approved answer,
`unsupported_media` validation, zero usage, persisted raw/canonical state, no research or reply job,
no reply intent, and idempotent duplicate execution. Add the equivalent image-limit test.

### Step 2: Write failing public capability tests

Assert a video response advances atomically to `reply_ready`, freezes exactly one shared reply intent,
and inserts exactly one reply job. Inject time, TID, and a job builder for deterministic assertions.
Assert no research job or provider-related field is created. Add rollback coverage for a failed reply
job insertion.

### Step 3: Run focused worker tests and verify failure

Run:

```bash
direnv exec . just test test/context_bot/workers/thread_worker_test.exs
```

Expected: unsupported results do not match the current canonicalizer success path and no direct
handoff exists.

### Step 4: Implement typed handoffs

Persist the raw and canonical snapshots for supported and known-unsupported results. Supported media
continues to enqueue research. Dry-run limitations transition directly to `complete` with explicit
zero usage and no job. Public limitations use the shared intent builder and transition directly to
`reply_ready` with one reply job. Thread failures remain content-free and terminal.

### Step 5: Run worker and workflow tests

Run:

```bash
direnv exec . just test test/context_bot/workers/thread_worker_test.exs test/context_bot/dry_run_workflow_test.exs test/context_bot/live_run_workflow_test.exs
```

Expected: pass.

## Task 6: Update Dry-Run Output and Recovery Assumptions

**Files:**

- Modify: `lib/mix/tasks/context_bot.dry_run.ex`
- Modify: `test/mix/tasks/context_bot.dry_run_test.exs`
- Modify: `lib/context_bot/workers/deferred_worker.ex` only if its durable-stage predicate needs v2
  media awareness
- Modify: `test/context_bot/workers/deferred_worker_test.exs` only if recovery behavior changes
- Modify: `lib/context_bot/workflow/reprocessor.ex` only if clearing/replaying canonical media is
  required
- Modify: `test/context_bot/workflow/reprocessor_test.exs` only if reprocess behavior changes

### Step 1: Add failing zero-usage output coverage

Complete a dry run with the deterministic video answer and a zero-valued usage map. Assert the CLI
prints input tokens, output tokens, tool uses, and cost as zero without crashing or implying a
provider request.

### Step 2: Run the focused CLI test and verify failure if present

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.dry_run_test.exs
```

Expected: either the new assertion exposes a missing case or documents that existing nil-safe output
already satisfies the requirement. Do not modify production code merely to make a non-failing test
fail.

### Step 3: Audit recovery and reprocessing predicates

Prove with focused tests that v2 supported rows recover through research, `reply_ready` limitation
rows recover only through reply publication, completed dry runs remain terminal, and reprocessing a
provider failure retains the frozen v2 request. Change predicates only where tests expose a real gap.

### Step 4: Run affected focused tests

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.dry_run_test.exs test/context_bot/workers/deferred_worker_test.exs test/context_bot/workflow/reprocessor_test.exs
```

Expected: pass.

## Task 7: Document the Behavior and Capture the Reusable Lesson

**Files:**

- Modify: `README.md`
- Modify: `.env.example` only if configuration changes were actually introduced
- Create: `knowledge-base/reports/2026-08-24-bluesky-media-provider-boundaries.md`
- Modify: `knowledge-base/learnings.md`

### Step 1: Update operator documentation

Document image support, the four-image bound, the deterministic video reply, zero Anthropic spend for
capability replies, and the fact that dry runs do not publish. Do not promise video support.

### Step 2: Record the provider-boundary learning

Use the `update-knowledge-base` skill because this investigation produced reusable constraints:
Bluesky AppView image URLs can be represented as bounded Anthropic URL blocks, Anthropic does not
accept video input in Messages vision, and xAI exposes X-only video understanding without publishing
its underlying pipeline.

### Step 3: Run documentation checks

Run:

```bash
git diff --check
direnv exec . just format-check
```

Expected: pass.

## Task 8: Verify, Review, and Commit the Implementation

**Files:** All modified implementation, test, migration, fixture, and documentation files.

### Step 1: Run targeted media tests together

Run:

```bash
direnv exec . just test test/context_bot/thread/canonicalizer_test.exs test/context_bot/research/request_test.exs test/context_bot/research/runner_test.exs test/context_bot/reply/intent_test.exs test/context_bot/workers/thread_worker_test.exs test/context_bot/workers/research_worker_test.exs
```

Expected: pass.

### Step 2: Use the verification-before-completion skill and run the full gate

Run:

```bash
direnv exec . just check
```

Expected: complete success with fresh output. Do not claim completion from earlier focused runs.

### Step 3: Review the complete diff

Run:

```bash
git status --short
git diff --check
git diff --stat main...HEAD
git diff main...HEAD
```

Confirm that no credential, local database, `.env`, build artifact, or unrelated user file is
included and that public-write tests use fakes only.

### Step 4: Commit the implementation

Commit all task changes with a concise message explaining image support and video fail-closed
behavior. Keep the prior design and plan commits linear on `codex/media-support`.

## Task 9: Create the Future Video GitHub Issue

**External effect:** Creating the issue is an authorized representational write requested by the
operator. If the only available route is the signed-in browser, obtain the browser skill's required
confirmation immediately before clicking the final Create/Submit control.

### Step 1: Recheck repository and authentication

Run read-only checks:

```bash
direnv exec . gh repo view social-protocols/context-bot
direnv exec . gh auth status
```

If CLI authentication remains invalid, use the in-app browser's existing signed-in GitHub session or
ask the operator to authenticate. Do not install an unrelated plugin.

### Step 2: Create the issue

Use this title:

```text
Support bounded video understanding for Bluesky embeds
```

The body must include:

- the current deterministic video fallback and why silent omission is unsafe;
- Anthropic's static-image-only Messages vision boundary;
- xAI X Search's `enable_video_understanding` precedent and the fact that its implementation is not
  public and is X-specific;
- a spike comparing a video-capable provider with bounded local fetch/frame/audio extraction;
- strict origin, byte, duration, frame, audio, time, storage, and spend caps;
- durable exact inputs, ancestor-only capture, dry-run non-publication, and exactly-once publication;
- provenance/synthetic-origin evaluation and uncertainty requirements; and
- behavior-first acceptance tests with no live or paid automated calls.

Include official links:

- `https://platform.claude.com/docs/en/build-with-claude/vision`
- `https://docs.x.ai/developers/tools/x-search`

### Step 3: Verify the issue

Open or fetch the created issue read-only and confirm its title/body. Record the issue URL in the
completion report; do not edit project boards, milestones, assignees, or labels unless explicitly
requested.
