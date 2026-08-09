# Local Read-Only Dry Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `just dry-run <post> <question>` to durably fetch public Bluesky context, call Anthropic under existing budget controls, retain the result in local SQLite, and make publication impossible.

**Architecture:** A persisted `dry_run` boolean selects a public-read-only thread path and terminal research handoff. A strict post parser and unauthenticated AppView client feed the existing thread and research workers; a Mix task starts only thread/research Oban queues. Secret loading becomes subset-aware so dry-run requires only Anthropic while deployment still requires every deployment secret.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix 1.8, Ecto/SQLite, Oban Lite, Req, ExUnit, Bash, Devbox, and Just.

## Global Constraints

- Run commands through `direnv exec .` from `.worktrees/context-bot-mvp`.
- Use strict red-green-refactor TDD and observe every new behavior test fail for the intended reason.
- `dry_run` is non-null with database default `false`; only the operator command sets it true.
- A dry run may perform public AppView reads and paid Anthropic requests, but never start an ATProto session, poll notifications, access repository records, or enqueue publication.
- AppView reads use the trusted `APPVIEW_URL`, `depth=0`, bounded `parentHeight`, raw-body limits, and no authorization or `atproto-proxy` header.
- Dry runs skip eligibility and mention rates but retain every Anthropic budget, token, tool, retry, timeout, response, and storage limit.
- Secrets and provider artifacts are never printed.
- Do not make a real Bluesky or Anthropic call without a supplied post and separate operator authorization.
- Commit each task and keep history linear.

---

### Task 1: Persist a Permanently Local Invocation

**Files:**
- Create: `priv/repo/migrations/20260809000000_add_dry_run_invocations.exs`
- Modify: `lib/context_bot/workflow/invocation.ex`
- Modify: `lib/context_bot/workflow/store.ex`
- Test: `test/context_bot/workflow/invocation_test.exs`
- Test: `test/context_bot/workflow/store_test.exs`

**Interfaces:**
- Consumes: normalized target AT URI, question, timestamp, and a two-argument thread-job builder.
- Produces: `Store.create_dry_run/4` and invocation fields `dry_run`, `target_uri`, `invocation_text`.

- [ ] **Step 1: Add failing schema and store tests.**

Prove public rows default to `dry_run: false`, dry-run rows require both local-input fields, and the store creates only thread work:

```elixir
job_builder = fn uri, cid ->
  Oban.Job.new(
    %{"uri" => uri, "cid" => cid},
    worker: "ContextBot.Workers.ThreadWorker",
    queue: :thread
  )
end

assert {:ok, invocation} =
         Store.create_dry_run(
           "at://did:plc:target/app.bsky.feed.post/3test",
           "What's missing?",
           ~U[2026-08-09 12:00:00.000000Z],
           job_builder
         )

assert invocation.dry_run
assert invocation.stage == :capturing_thread
assert invocation.target_uri == "at://did:plc:target/app.bsky.feed.post/3test"
assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "eligibility"), :count) == 0
```

Use a job-builder function because the local URI/CID are generated inside the operation. Assert two calls have unique identities with `local://context-bot/dry-runs/` and `local:` prefixes. Reject blank, invalid UTF-8, and questions over 10,000 bytes without a row/job.

- [ ] **Step 2: Run focused tests and verify RED.**

```bash
direnv exec . mix test test/context_bot/workflow/invocation_test.exs test/context_bot/workflow/store_test.exs
```

Expected: missing schema fields and `create_dry_run/4`.

- [ ] **Step 3: Add migration and schema support.**

```elixir
alter table(:invocations) do
  add :dry_run, :boolean, null: false, default: false
  add :target_uri, :text
  add :invocation_text, :text
end

create constraint(:invocations, :dry_run_input_check,
         check:
           "dry_run = 0 OR (target_uri IS NOT NULL AND length(target_uri) > 0 AND " <>
             "invocation_text IS NOT NULL AND length(invocation_text) > 0)"
       )
```

Cast the three fields on receipt, validate the constraint, and preserve existing public changesets.

- [ ] **Step 4: Implement the atomic store operation.**

Generate `run_id = Ecto.UUID.generate()`, derive the two local identifiers, build the thread job with `job_builder.(uri, cid)`, and insert invocation/job in one `Ecto.Multi`. Use `actor_did: "local:operator"`, a bounded raw local-request map, and `status/stage: :capturing_thread`. Return `{:error, :invalid_input}` before a transaction for invalid question input.

- [ ] **Step 5: Verify regressions and commit.**

```bash
direnv exec . mix test test/context_bot/workflow/invocation_test.exs \
  test/context_bot/workflow/store_test.exs test/context_bot/mentions/poller_test.exs
git add priv/repo/migrations/20260809000000_add_dry_run_invocations.exs \
  lib/context_bot/workflow/invocation.ex lib/context_bot/workflow/store.ex \
  test/context_bot/workflow/invocation_test.exs test/context_bot/workflow/store_test.exs
git commit -m "feat: persist local dry-run invocations"
```

---

### Task 2: Normalize Strict Public Post References

**Files:**
- Create: `lib/context_bot/dry_run/post_reference.ex`
- Create: `test/context_bot/dry_run/post_reference_test.exs`

**Interfaces:**
- Consumes: a `bsky.app` post URL or post AT URI and a module implementing `resolve_handle/1`.
- Produces: `PostReference.normalize/2 :: (String.t(), module()) -> {:ok, String.t()} | {:error, atom()}` with a canonical DID-based post URI.

- [ ] **Step 1: Write table-driven failing tests.**

```elixir
assert {:ok, "at://did:plc:alice/app.bsky.feed.post/3abc"} =
         PostReference.normalize("https://bsky.app/profile/alice.example/post/3abc", Resolver)
assert_received {:resolve_handle, "alice.example"}

assert {:ok, "at://did:plc:alice/app.bsky.feed.post/3abc"} =
         PostReference.normalize("at://did:plc:alice/app.bsky.feed.post/3abc", Resolver)
refute_received {:resolve_handle, _}
```

Reject lookalike hosts, HTTP, credentials, ports, queries, fragments, extra segments, other collections, invalid handles/DIDs/rkeys, and oversized input. Handle resolution accepts only a successful map containing a valid DID.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . mix test test/context_bot/dry_run/post_reference_test.exs
```

Expected: undefined `PostReference`.

- [ ] **Step 3: Implement bounded parsing.**

Use `URI.new/1` with exact web-path matching and a bounded AT-URI parser that permits a handle before resolution. Reuse `ContextBot.ATProto.ATURI.parse/1` for the final DID URI. Handles are lowercase, at most 253 bytes, contain at least two valid DNS labels, and resolve via:

```elixir
{:ok, status, _headers, %{"did" => did}} when status in 200..299 -> canonical_uri(did, rkey)
{:error, reason} -> {:error, reason}
_ -> {:error, :invalid_post_reference}
```

- [ ] **Step 4: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/dry_run/post_reference_test.exs \
  test/context_bot/atproto/at_uri_test.exs
git add lib/context_bot/dry_run/post_reference.ex test/context_bot/dry_run/post_reference_test.exs
git commit -m "feat: normalize dry-run post references"
```

---

### Task 3: Add an Unauthenticated Public AppView Boundary

**Files:**
- Create: `lib/context_bot/atproto/public_client.ex`
- Create: `test/context_bot/atproto/public_client_test.exs`
- Modify: `config/test.exs`

**Interfaces:**
- Consumes: trusted AppView URL plus configured timeout/body limits.
- Produces: `PublicClient.resolve_handle/1` and `PublicClient.get_post_thread/2` in the existing ATProto result shape.

- [ ] **Step 1: Write failing Req boundary tests.**

Assert exact host, method, XRPC path, handle/thread params, `depth=0`, and bounded `parentHeight`. Every handler asserts:

```elixir
assert Plug.Conn.get_req_header(conn, "authorization") == []
assert Plug.Conn.get_req_header(conn, "atproto-proxy") == []
```

Cover success, raw response overflow, timeout, malformed JSON, 429 retry-after, 5xx, and permanent non-2xx.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . mix test test/context_bot/atproto/public_client_test.exs
```

Expected: undefined `PublicClient`.

- [ ] **Step 3: Implement the read-only client.**

Request `/xrpc/com.atproto.identity.resolveHandle` and `/xrpc/app.bsky.feed.getPostThread` directly from `APPVIEW_URL`. Set `raw: true`, attach `ContextBot.HTTP.BodyLimit`, decode only bounded JSON, and normalize errors like `ReqClient`. Implement no notifications, profiles, DID documents, session, or repository methods.

- [ ] **Step 4: Verify authenticated and public boundaries together; commit.**

```bash
direnv exec . mix test test/context_bot/atproto/public_client_test.exs \
  test/context_bot/atproto/req_client_test.exs
git add lib/context_bot/atproto/public_client.ex test/context_bot/atproto/public_client_test.exs \
  config/test.exs
git commit -m "feat: read public AppView without a session"
```

---

### Task 4: Capture a Synthetic Invocation Beneath the Real Thread

**Files:**
- Modify: `lib/context_bot/thread/canonicalizer.ex`
- Modify: `lib/context_bot/workers/thread_worker.ex`
- Modify: `test/context_bot/thread/canonicalizer_test.exs`
- Modify: `test/context_bot/workers/thread_worker_test.exs`

**Interfaces:**
- Consumes: dry-run invocation and public thread response for `target_uri`.
- Produces: `Canonicalizer.build_dry_run/2`, a `thread_ready` checkpoint, and research job.

- [ ] **Step 1: Add failing canonicalization tests.**

```elixir
Canonicalizer.build_dry_run(thread, %{
  target_uri: "at://did:plc:alice/app.bsky.feed.post/invocation",
  invocation_text: "Is this fair?",
  parent_height: 80
})
```

Assert literal order: root ancestor, immediate parent, real `[target]`, then `[invocation]` with only the operator question. Assert no descendants/media bodies and no bot-DID or mention-facet requirement. Cover wrong/unavailable target, blocked ancestors, and truncation.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . mix test test/context_bot/thread/canonicalizer_test.exs
```

Expected: undefined `build_dry_run/2`.

- [ ] **Step 3: Reuse existing traversal in one canonicalizer.**

Reuse `available_post/1`, target matching, root derivation, ancestor traversal, and render helpers, but skip current-mention validation. Return real target CID/root; publication never consumes local identity.

- [ ] **Step 4: Add failing worker-routing tests.**

Assert public work still calls authenticated client with `invocation_uri`; dry-run work calls an injected public client with `target_uri`, stores the local question in canonical text, and enqueues research only.

- [ ] **Step 5: Run and verify RED, then route by persisted state.**

```bash
direnv exec . mix test test/context_bot/workers/thread_worker_test.exs
```

Add `public_client` dependencies and select source from the row:

```elixir
defp thread_source(%Invocation{dry_run: true, target_uri: uri}, dependencies),
  do: {dependencies.public_client, uri}

defp thread_source(%Invocation{invocation_uri: uri}, dependencies),
  do: {dependencies.client, uri}
```

Keep HTTP outside transactions and the thread-to-research handoff atomic.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . mix test test/context_bot/thread/canonicalizer_test.exs \
  test/context_bot/workers/thread_worker_test.exs
git add lib/context_bot/thread/canonicalizer.ex lib/context_bot/workers/thread_worker.ex \
  test/context_bot/thread/canonicalizer_test.exs test/context_bot/workers/thread_worker_test.exs
git commit -m "feat: capture dry-run thread context"
```

---

### Task 5: Complete Research Without Publication

**Files:**
- Modify: `lib/context_bot/workers/research_worker.ex`
- Modify: `lib/context_bot/workers/reply_worker.ex`
- Modify: `test/context_bot/workers/research_worker_test.exs`
- Modify: `test/context_bot/workers/reply_worker_test.exs`

**Interfaces:**
- Consumes: claimed dry-run invocation and normal successful runner result.
- Produces: terminal `complete` state with evidence and no publication fields/job.

- [ ] **Step 1: Add a failing successful-research test.**

Seed `thread_ready`, `dry_run: true`, and settings without bot DID. Assert after perform:

```elixir
assert persisted.stage == :complete
assert persisted.selected_reply == "A concise tested answer."
assert persisted.completed_at
assert persisted.reply_repo == nil
assert persisted.reply_rkey == nil
assert persisted.reply_record == nil
assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "reply"), :count) == 0
```

Also assert messages, usage, validation, and response envelopes remain retained.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . mix test test/context_bot/workers/research_worker_test.exs
```

Expected: current code requires a publication DID.

- [ ] **Step 3: Add terminal dry-run handoff.**

After runner success, branch before public reply construction. Under the existing research claim, transition directly to `complete` with selected reply/messages/usage/validation, cleared claim/defer/failure fields, `completed_at`, and no next job. Preserve public behavior.

- [ ] **Step 4: Add a failing publication-defense test.**

Manually seed a malformed `dry_run: true` row at `reply_ready` with a valid-looking record, execute a reply job, and assert no public client call or `publishing` claim.

- [ ] **Step 5: Run RED, add the guard, verify and commit.**

Ignore `Invocation{dry_run: true}` before claim acquisition, then run:

```bash
direnv exec . mix test test/context_bot/workers/research_worker_test.exs \
  test/context_bot/workers/reply_worker_test.exs test/context_bot/research/runner_test.exs
git add lib/context_bot/workers/research_worker.ex lib/context_bot/workers/reply_worker.ex \
  test/context_bot/workers/research_worker_test.exs test/context_bot/workers/reply_worker_test.exs
git commit -m "feat: complete dry runs without publication"
```

---

### Task 6: Load Only the Secrets Each Command Requires

**Files:**
- Modify: `secrets.sh`
- Modify: `test/secrets_test.sh`
- Modify: `config/runtime.exs`
- Modify: `test/context_bot_web/production_config_test.exs`
- Modify: `justfile`

**Interfaces:**
- Consumes: allowlisted secret names passed to sourced `secrets.sh`.
- Produces: only requested exports; Anthropic runtime config while `BOT_ENABLED=false`.

- [ ] **Step 1: Add failing sourced-script tests.**

```bash
source "$project_root/secrets.sh" ANTHROPIC_API_KEY
[[ "$ANTHROPIC_API_KEY" == "anthropic-key-test-value" ]]
[[ -z "${FLY_API_TOKEN+x}" ]]
[[ -z "${SECRET_KEY_BASE+x}" ]]
[[ -z "${BOT_APP_PASSWORD+x}" ]]
```

Use an Anthropic-only Bitwarden fixture. Cover empty requests, unsupported/duplicate names, missing requested fields, xtrace restoration, failure cleanup, four-name deployment loading, and absence of values in output.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . bash test/secrets_test.sh
```

Expected: current script requires all four.

- [ ] **Step 3: Implement subset loading.**

Validate positional names against the fixed allowlist before `bw`; reject empty input; deduplicate without reordering. Stage requested values and export only after every requested field succeeds. Cleanup request lists and temporary values. Update `just secrets` and `just deploy` to request all four explicitly.

- [ ] **Step 4: Add failing runtime tests.**

Prove disabled bot plus nonempty `ANTHROPIC_API_KEY` configures Anthropic without bot identity/password. Prove enabled bot still requires both provider and bot secrets and never stores them in `%Settings{}`.

- [ ] **Step 5: Run RED and configure provider independently.**

```bash
direnv exec . mix test test/context_bot_web/production_config_test.exs
```

Read an optional nonempty Anthropic key into app config whenever present; the enabled branch still requires it and `BOT_APP_PASSWORD`.

- [ ] **Step 6: Verify and commit.**

```bash
direnv exec . bash test/secrets_test.sh
direnv exec . mix test test/context_bot_web/production_config_test.exs \
  test/context_bot/atproto/session_test.exs test/context_bot/research/anthropic_client_test.exs
git add secrets.sh test/secrets_test.sh config/runtime.exs \
  test/context_bot_web/production_config_test.exs justfile
git commit -m "feat: load command-specific secrets"
```

---

### Task 7: Add the Durable Operator Command and Acceptance Test

**Files:**
- Create: `lib/context_bot/dry_run.ex`
- Create: `lib/mix/tasks/context_bot.dry_run.ex`
- Create: `test/context_bot/dry_run_test.exs`
- Create: `test/context_bot/dry_run_workflow_test.exs`
- Create: `test/mix/tasks/context_bot.dry_run_test.exs`
- Modify: `justfile`
- Modify: `.env.example`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: post reference, question, Anthropic secret, non-nil daily budget, Repo/Finch, and minimal Oban.
- Produces: `DryRun.create/3`, `DryRun.await/2`, Mix task `context_bot.dry_run`, and `just dry-run post question`.

- [ ] **Step 1: Add failing service tests.**

Test `create/3` with injected reference client/clock. Invalid reference creates no row. Test `await/2` against real rows changing to `complete`, `failed`, and `deferred_budget`, using injected sleep to avoid wall-clock waits.

- [ ] **Step 2: Run and verify RED.**

```bash
direnv exec . mix test test/context_bot/dry_run_test.exs
```

Expected: undefined `ContextBot.DryRun`.

- [ ] **Step 3: Implement the service.**

```elixir
@spec create(String.t(), String.t(), keyword()) :: {:ok, Invocation.t()} | {:error, atom()}
@spec await(Invocation.t(), keyword()) ::
        {:ok, Invocation.t()} | {:error, Invocation.t()} | {:deferred, Invocation.t()}
```

`create/3` normalizes then delegates atomic insertion to Store. `await/2` reloads only the selected row until `complete`, `failed`, or `deferred_budget`; inject polling/sleep for tests.

- [ ] **Step 4: Add failing Mix-task tests.**

Capture Mix shell output. Wrong arity, `BOT_ENABLED=true`, missing daily budget, or missing configured Anthropic key fail before a row. A completed injected service result prints database ID, status, selected reply, and compact integer usage/cost—but no raw body, headers, API key, or prompt.

- [ ] **Step 5: Run and verify RED.**

```bash
direnv exec . mix test test/mix/tasks/context_bot.dry_run_test.exs
```

Expected: Mix task undefined.

- [ ] **Step 6: Implement minimal runtime and safe output.**

Require exactly two args; require disabled bot, configured Anthropic key, and daily budget; start default-named Oban from repo config with `queues: [thread: 1, research: 1]` and `plugins: []`; create/await; print safe summary. If Oban already runs, reuse it only if no reply queue/poller/session is active, otherwise fail closed.

- [ ] **Step 7: Add shell-safe Just recipe.**

```just
dry-run post question:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh ANTHROPIC_API_KEY
    BOT_ENABLED=false mix context_bot.dry_run {{quote(post)}} {{quote(question)}}
```

- [ ] **Step 8: Add failing durable end-to-end test.**

Use real SQLite, real Oban insertion/draining, real workers, and `Req.Test` only at public AppView/Anthropic boundaries. From a `bsky.app` URL assert unauthenticated handle/thread reads, ancestor+target+question context without descendants, settled budget, byte-exact provider envelope, validated `complete` result, zero eligibility/reply jobs, nil reply fields, and no session process. A second scenario exhausts budget and reaches `deferred_budget` without Anthropic.

- [ ] **Step 9: Run RED and wire only demonstrated seams.**

```bash
direnv exec . mix test test/context_bot/dry_run_workflow_test.exs --trace
```

Add only minimal dependency/config wiring shown missing by the failure; never start poller, session, reply queue, or maintenance plugin.

- [ ] **Step 10: Document operation and constraints.**

Document exact command, required Bitwarden field, daily budget, SQLite inspection, and that Bluesky is read-only while Anthropic is paid. Update `AGENTS.md`: `dry_run=true` is permanently non-publishable and agents need explicit authorization plus an operator-supplied post for a paid manual run.

- [ ] **Step 11: Verify the final tree without real provider calls.**

```bash
direnv exec . mix test test/context_bot/dry_run_test.exs \
  test/mix/tasks/context_bot.dry_run_test.exs \
  test/context_bot/dry_run_workflow_test.exs --trace
direnv exec . just setup
direnv exec . just check
direnv exec . just docker-build
git diff --check
```

Start the rebuilt image with `BOT_ENABLED=false` and a temporary SQLite mount; verify `/health` returns HTTP 200. Do not run the real dry-run command.

- [ ] **Step 12: Commit.**

```bash
git add lib/context_bot/dry_run.ex lib/mix/tasks/context_bot.dry_run.ex \
  test/context_bot/dry_run_test.exs test/context_bot/dry_run_workflow_test.exs \
  test/mix/tasks/context_bot.dry_run_test.exs justfile .env.example README.md AGENTS.md
git commit -m "feat: run durable local context checks"
```

---

## Final Review

- [ ] Trace the row from command input to `complete`; every safety branch uses persisted `dry_run`.
- [ ] Confirm no dry-run path constructs a reply record, starts a session, polls, or starts reply queue.
- [ ] Confirm AppView calls lack auth/proxy headers and enforce raw-body limits.
- [ ] Confirm real Anthropic budget/response ledgers handle success, failure, and deferral.
- [ ] Confirm secret subsets export exactly requested names and deploy still requests all four.
- [ ] Run `just check`, Docker build, diff check, and disabled-container health smoke from final tree.
- [ ] Commit review fixes separately.
- [ ] Ask for a post URL and explicit authorization before the first real paid dry run.
