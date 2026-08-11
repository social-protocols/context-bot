# Code-execution Envelope Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept Anthropic's documented dynamic-filtering response blocks and safely reprocess a failed invocation from its retained response without repeating paid research.

**Architecture:** Extend the pure reply block state machine with one paired server-tool type. Add a transactionally guarded workflow reprocessor and a thin Mix/just operator interface; the existing Runner performs envelope replay and any necessary bounded repair.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix, Ecto/SQLite, Oban, ExUnit, Devbox, just.

## Global Constraints

- Run every command through `direnv exec .`.
- Use behavior-first ExUnit tests and observe each new test fail before production changes.
- Never log response bodies, request text, credentials, or provider tool contents.
- Never repeat a research POST when a complete latest response envelope is retained.
- Run `direnv exec . just check` before integration.

---

### Task 1: Validate code-execution response blocks

**Files:**
- Modify: `test/context_bot/research/reply_test.exs`
- Modify: `test/context_bot/research/runner_test.exs`
- Modify: `lib/context_bot/research/reply.ex`
- Modify: `lib/context_bot/research/runner.ex`

**Interfaces:**
- Consumes: `Reply.select/2` and Runner's saved-message pending-tool reconstruction.
- Produces: support for paired `code_execution` / `code_execution_tool_result` blocks without exposing their contents as reply text.

- [ ] **Step 1: Write failing reply-selection tests**

Add an `end_turn` case with the live sequence `thinking`, `server_tool_use` named
`code_execution`, `code_execution_tool_result` with map content, and final `text`. Assert the text
is selected. Add separate assertions that missing IDs, non-map input/content, orphaned results,
duplicate IDs, mismatched IDs, and unknown server tools fail closed.

- [ ] **Step 2: Verify the selection tests fail for the missing capability**

Run: `direnv exec . mix test test/context_bot/research/reply_test.exs`

Expected: the valid code-execution case fails with `{:error, :unexpected_tool_use}`.

- [ ] **Step 3: Implement paired block validation**

Extend `valid_pending_server_tools?/1`, `collect_block/2`, `complete_tool/5`, and the relevant
result-type guards in `Reply`. Preserve the existing fail-closed behavior for every other block.

- [ ] **Step 4: Verify reply-selection tests pass**

Run: `direnv exec . mix test test/context_bot/research/reply_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Write and verify the failing Runner continuation test**

Add a test whose saved assistant pause contains a code-execution call and whose recorded
continuation begins with its result. Assert replay selects the final text and the fake client is
not invoked for the already-recorded attempt.

Run: `direnv exec . mix test test/context_bot/research/runner_test.exs`

Expected: the test fails because Runner does not reconstruct the pending code-execution call.

- [ ] **Step 6: Implement Runner pending-pair tracking and verify**

Teach `pending_server_tools/1` to add `code_execution` calls and remove matching
`code_execution_tool_result` blocks. Keep web-use accounting unchanged.

Run: `direnv exec . mix test test/context_bot/research/runner_test.exs test/context_bot/research/reply_test.exs`

Expected: all tests pass.

### Task 2: Add guarded retained-envelope reprocessing

**Files:**
- Create: `lib/context_bot/workflow/reprocessor.ex`
- Create: `test/context_bot/workflow/reprocessor_test.exs`
- Modify: `lib/context_bot/workflow/store.ex`

**Interfaces:**
- Consumes: an integer invocation ID, `Budget.unrecorded_exposed_attempt/1`, latest `BudgetEntry`, and its `ResponseEnvelope`.
- Produces: `ContextBot.Workflow.Reprocessor.reprocess/2 :: {:ok, Invocation.t()} | {:error, atom()}` and an atomic Store transition back to `thread_ready` with one research job.

- [ ] **Step 1: Write failing guard and transition tests**

Create fixtures for an eligible failed invocation with a settled 2xx JSON envelope. Assert dry
and public queue selection, cleared terminal/claim fields, preserved response and budget rows, and
exactly one available research job. Assert rejection of nonexistent, nonterminal, non-provider,
missing-context, missing-envelope, unrecorded-exposure, non-2xx, and malformed-JSON cases.

- [ ] **Step 2: Verify the reprocessor tests fail because the module is absent**

Run: `direnv exec . mix test test/context_bot/workflow/reprocessor_test.exs`

Expected: compilation fails because `ContextBot.Workflow.Reprocessor` is undefined.

- [ ] **Step 3: Implement the guarded immediate transaction**

Resolve and validate the invocation and latest attempt inside `Repo.transaction(mode: :immediate)`.
Use a compare-and-update from `failed`, clear failure/completion/claim/defer fields, and insert an
Oban job on `dry_research` or `research` in the same transaction. Return stable atom errors only.

- [ ] **Step 4: Verify the reprocessor tests pass**

Run: `direnv exec . mix test test/context_bot/workflow/reprocessor_test.exs`

Expected: all tests pass.

- [ ] **Step 5: Add and verify concurrent idempotence coverage**

Use two sandbox-authorized tasks to request the same reprocessing operation. Assert exactly one
returns success, the other fails as nonterminal/stale, and only one incomplete research job exists.

Run: `direnv exec . mix test test/context_bot/workflow/reprocessor_test.exs`

Expected: all tests pass consistently.

### Task 3: Add the operator command

**Files:**
- Create: `lib/mix/tasks/context_bot.reprocess.ex`
- Create: `test/mix/tasks/context_bot.reprocess_test.exs`
- Modify: `justfile`
- Modify: `README.md`

**Interfaces:**
- Consumes: `mix context_bot.reprocess INVOCATION_ID` and `Reprocessor.reprocess/2`.
- Produces: `just reprocess INVOCATION_ID`, printing only safe status/ID fields.

- [ ] **Step 1: Write failing Mix task tests**

Inject a fake reprocessor, assert strict positive-integer parsing, worker-free database runtime
startup, success output, and credential-safe errors for every rejected result.

- [ ] **Step 2: Verify the task tests fail because the task is absent**

Run: `direnv exec . mix test test/mix/tasks/context_bot.reprocess_test.exs`

Expected: compilation fails because `Mix.Tasks.ContextBot.Reprocess` is undefined.

- [ ] **Step 3: Implement the Mix task and just recipe**

Add the thin task, `reprocess invocation_id:` recipe, and README operator instructions explaining
that the bot must be disabled and local workers stopped, processing resumes on the next normal
runtime start, and a bounded repair call may still occur.

- [ ] **Step 4: Verify focused command and workflow tests**

Run: `direnv exec . mix test test/mix/tasks/context_bot.reprocess_test.exs test/context_bot/workflow/reprocessor_test.exs test/context_bot/research/reply_test.exs test/context_bot/research/runner_test.exs`

Expected: all tests pass.

### Task 4: Verify, review, integrate, and replay invocation 3

**Files:**
- Modify if warranted: `knowledge-base/reports/2026-08-11-anthropic-code-execution-replay.md`
- Modify if warranted: `knowledge-base/learnings.md`

**Interfaces:**
- Consumes: completed implementation, invocation 3 in the main checkout database, and the user's existing dry-run command.
- Produces: reviewed code on `main` and invocation 3 reopened from its retained envelope.

- [ ] **Step 1: Record the reusable provider-contract lesson**

Document that dated Anthropic web tools can emit outer code-execution pairs under dynamic
filtering even with excluded result inclusion, and that recorded envelopes must be replayed rather
than re-requested after local parsing failures.

- [ ] **Step 2: Run the complete verification gate**

Run: `direnv exec . just check`

Expected: exit 0 with every ExUnit and shell test passing, formatting clean, Credo clean, and
Dialyzer successful.

- [ ] **Step 3: Request independent code review and resolve findings**

Review the complete branch diff against the design, focusing on malformed block acceptance,
transaction races, duplicate jobs, and accidental provider replay.

- [ ] **Step 4: Commit and fast-forward `main`**

Commit the verified changes, integrate the feature branch into `main` without a merge commit, and
rerun `direnv exec . just check` on the integrated tree.

- [ ] **Step 5: Reopen invocation 3 without processing it yet**

Run: `direnv exec . just reprocess 3`

Expected: prints `status=reopened` and `invocation_id=3`; its existing research budget/envelope
rows remain unchanged and exactly one dry research job becomes available.

- [ ] **Step 6: Resume through the normal command and verify bounded spend**

Run the original `just dry-run` command. Expected: it attaches to invocation 3, processes the
stored research envelope, sends at most one length-repair request, and completes without posting
to Bluesky. Compare the budget ledger before and after to prove no second research attempt exists.
