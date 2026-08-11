# Automatic Workflow Catch-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `just dry-run` attach to matching unfinished work and safely process all pending local dry-run jobs through automatic startup catch-up.

**Architecture:** Split local startup into a base-application phase and a worker phase so invocation selection occurs before any queue can dispatch. Use one immediate SQLite transaction for find-or-create, reuse the existing recovery matrix, and expose filtered due-deferral reconciliation that preserves dry/public queue separation.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix, Ecto SQLite, Oban, ExUnit, Devbox, direnv, Just.

## Global Constraints

- Run every command through `direnv exec .` inside the isolated worktree.
- Follow strict red-green-refactor: no production behavior changes before a test fails for the intended reason.
- Local mode must never start ATProto authentication, notification polling, public queues, or publication.
- Anthropic attempts remain governed by the daily budget and ambiguous `sent` attempts are never replayed.
- Exact matching uses normalized target AT URI plus byte-for-byte question text.
- `complete`, `failed`, and `ineligible` are terminal and never attachable.
- All logs and CLI errors must remain finite and free of provider, prompt, thread, question, and credential content.
- Do not start the live development database's pending jobs during implementation or verification.

---

### Task 1: Atomic Dry-run Find-or-create

**Files:**
- Modify: `test/context_bot/workflow/store_test.exs`
- Modify: `lib/context_bot/workflow/store.ex`
- Modify: `test/context_bot/dry_run_test.exs`
- Modify: `lib/context_bot/dry_run.ex`
- Modify: `test/context_bot/dry_run_workflow_test.exs`

**Interfaces:**
- Produces: `Store.create_or_attach_dry_run/4 :: {:ok, Invocation.t(), :created | :attached} | {:error, :invalid_input}`.
- Produces: `DryRun.prepare/3 :: {:ok, Invocation.t(), :created | :attached} | {:error, atom()}`.
- Matching terminal stages: `[:complete, :failed, :ineligible]`.

- [ ] **Step 1: Write failing store tests for attachment and deliberate repeats**

Add behavior tests that insert through the real Repo and assert literal row/job counts:

```elixir
test "attaches to the newest matching nonterminal dry run without inserting another job" do
  assert {:ok, first, :created} =
           Store.create_or_attach_dry_run(@target_uri, "Question", @received_at, &thread_job/2)

  newer = DateTime.add(@received_at, 1, :second)
  duplicate = dry_invocation!(@target_uri, "Question", newer, :thread_ready)

  assert {:ok, attached, :attached} =
           Store.create_or_attach_dry_run(@target_uri, "Question", @received_at, &thread_job/2)

  assert attached.id == duplicate.id
  assert attached.id != first.id
  assert Repo.aggregate(Invocation, :count) == 2
  assert Repo.aggregate(Oban.Job, :count) == 1
end

test "creates a new run after a matching invocation becomes terminal" do
  terminal = dry_invocation!(@target_uri, "Question", @received_at, :complete)

  assert {:ok, created, :created} =
           Store.create_or_attach_dry_run(@target_uri, "Question", @received_at, &thread_job/2)

  assert created.id != terminal.id
  assert Repo.aggregate(Invocation, :count) == 2
  assert Repo.aggregate(Oban.Job, :count) == 1
end
```

Also cover exact question matching, public-row exclusion, and invalid input without durable writes.

- [ ] **Step 2: Run the focused store tests and verify RED**

Run:

```bash
direnv exec . just test test/context_bot/workflow/store_test.exs
```

Expected: failures because `create_or_attach_dry_run/4` does not exist.

- [ ] **Step 3: Implement transactional lookup and insertion**

Inside `Repo.transaction(mode: :immediate)`, query newest-first by `received_at` and `id`:

```elixir
def create_or_attach_dry_run(target_uri, question, %DateTime{} = received_at, job_builder) do
  if valid_dry_run_input?(target_uri, question) do
    Repo.transaction(
      fn ->
        case attachable_dry_run(target_uri, question) do
          %Invocation{} = invocation -> {invocation, :attached}
          nil -> insert_dry_run!(target_uri, question, received_at, job_builder)
        end
      end,
      mode: :immediate
    )
    |> normalize_dry_run_transaction()
  else
    {:error, :invalid_input}
  end
end
```

Keep identity generation and job insertion in the same transaction. The helper query must require
`dry_run == true`, exact target/question equality, and stage outside the terminal set.

- [ ] **Step 4: Run the store tests and verify GREEN**

Run the same focused command. Expected: all store tests pass with no duplicate row or job.

- [ ] **Step 5: Write failing service tests for normalize-before-attach behavior**

Change service tests to expect `DryRun.prepare/3`, including:

```elixir
assert {:ok, invocation, :created} = DryRun.prepare(url, "Is this fair?", options)
assert {:ok, same, :attached} = DryRun.prepare(url, "Is this fair?", options)
assert same.id == invocation.id
```

Assert the post-reference normalizer is called on both attempts and only the normalized DID URI is
persisted.

- [ ] **Step 6: Run service/workflow tests and verify RED**

Run:

```bash
direnv exec . just test test/context_bot/dry_run_test.exs test/context_bot/dry_run_workflow_test.exs
```

Expected: failures because `prepare/3` is absent and current code always creates.

- [ ] **Step 7: Implement `DryRun.prepare/3` and update callers in workflow tests**

Validate the question first, normalize through `PostReference`, then call
`Store.create_or_attach_dry_run/4`. Remove the old always-new `create/3` API rather than keeping two
operator semantics.

- [ ] **Step 8: Run the focused service/workflow tests and commit**

Run the focused tests until green, then:

```bash
git add lib/context_bot/dry_run.ex lib/context_bot/workflow/store.ex test/context_bot/dry_run_test.exs test/context_bot/dry_run_workflow_test.exs test/context_bot/workflow/store_test.exs
git commit -m "Attach dry runs to matching pending work"
```

---

### Task 2: Workflow-aware Due-deferral Reconciliation

**Files:**
- Modify: `test/context_bot/workers/deferred_worker_test.exs`
- Modify: `lib/context_bot/workers/deferred_worker.ex`

**Interfaces:**
- Produces: `DeferredWorker.reconsider_due/1 :: :ok | {:error, :deferred_reconciliation_failed}`.
- Options: `now: DateTime.t()`, `settings: Settings.t()`, `workflow: :all | :dry_run`, and `attempt_index: non_neg_integer()`.
- `DeferredWorker.perform/1` continues to run general recovery, then delegates due work to the new function with `workflow: :all`.

- [ ] **Step 1: Write failing tests for dry-only due reconciliation**

Create a due dry invocation with canonical thread state but no public eligibility evidence, a due
public invocation, and a future dry invocation. Call the real function:

```elixir
assert :ok =
         DeferredWorker.reconsider_due(
           now: @now,
           settings: settings(),
           workflow: :dry_run,
           attempt_index: 1
         )

assert Repo.reload!(due_dry).stage == :thread_ready
assert Repo.reload!(due_public).stage == :deferred_budget
assert Repo.reload!(future_dry).stage == :deferred_budget

assert [%Oban.Job{queue: "dry_research", worker: "ContextBot.Workers.ResearchWorker"}] =
         Repo.all(from job in Oban.Job, where: job.args == ^job_args(due_dry))
```

The production break caught is selecting public candidates, rejecting valid dry rows for missing
eligibility metadata, or enqueueing dry research on `research`.

- [ ] **Step 2: Run the deferred-worker tests and verify RED**

Run:

```bash
direnv exec . just test test/context_bot/workers/deferred_worker_test.exs
```

Expected: failure because `reconsider_due/1` does not exist.

- [ ] **Step 3: Extract a public reconciliation entry point**

Refactor the existing claim/enqueue path without changing `perform/1` semantics:

```elixir
def reconsider_due(options \\ []) do
  dependencies = dependencies(options)
  workflow = Keyword.get(options, :workflow, :all)
  attempt_index = Keyword.get(options, :attempt_index, 1)

  dependencies
  |> claim_batch(workflow)
  |> process_claimed_work(attempt_index)
rescue
  _database_or_state_error -> {:error, :deferred_reconciliation_failed}
end
```

Filter the candidate query before claiming when `workflow == :dry_run`. Treat a dry invocation as
accepted when its canonical thread/current CID are durable; retain the existing eligibility and
admission checks for public work. Choose `dry_research` or `research` from `invocation.dry_run`.

- [ ] **Step 4: Preserve maintenance-worker behavior**

Make `perform/1` call recovery first and then `reconsider_due/1` with `workflow: :all` and
`attempt_index: job.attempt`. Existing capacity, rate, budget, recovery, and logging tests must
remain green.

- [ ] **Step 5: Run the focused tests and commit**

Run the deferred-worker test file until green, then:

```bash
git add lib/context_bot/workers/deferred_worker.ex test/context_bot/workers/deferred_worker_test.exs
git commit -m "Reconcile due dry-run budget deferrals"
```

---

### Task 3: Two-phase Safe Local Runtime

**Files:**
- Modify: `test/context_bot/dry_run/runtime_test.exs`
- Modify: `lib/context_bot/dry_run/runtime.ex`

**Interfaces:**
- Produces: `Runtime.ensure_application_started/0 :: :ok | {:error, atom()}`.
- Produces: `Runtime.start_workers/1 :: :ok | {:error, atom()}`.
- `start_workers/1` accepts injectable `recovery`, `deferred`, and `now` dependencies for tests.
- Retains: `Runtime.stop/1` and `Runtime.safe_oban_config?/2`.

- [ ] **Step 1: Write failing base-phase tests**

Assert `ensure_application_started/0` starts the Repo but leaves Oban absent, and rejects enabled bot
settings or registered public children. The key literal assertion is:

```elixir
assert :ok = Runtime.ensure_application_started()
assert is_pid(Process.whereis(ContextBot.Repo))
assert Oban.whereis(Oban) == nil
```

- [ ] **Step 2: Run runtime tests and verify RED**

Run:

```bash
direnv exec . just test test/context_bot/dry_run/runtime_test.exs
```

Expected: failure because the two-phase API does not exist.

- [ ] **Step 3: Implement the base phase**

Move application startup and public-child checks from `ensure_started/1` into
`ensure_application_started/0`. Fail closed if any Oban instance is already running; selection must
always happen before consumers.

- [ ] **Step 4: Write failing worker-phase ordering tests**

Use fakes that send messages to assert exact ordering and state:

```elixir
assert :ok = Runtime.start_workers(recovery: FakeRecovery, deferred: FakeDeferred, now: fn -> @now end)
assert_receive {:recovery, [startup?: true, now: @now], nil}
assert_receive {:deferred, [workflow: :dry_run, now: @now], nil}
assert Oban.whereis(Oban)
```

Also assert either recovery or deferral failure leaves Oban stopped.

- [ ] **Step 5: Run runtime tests and verify RED**

Expected: failures because `start_workers/1` and filtered deferral reconciliation are not wired.

- [ ] **Step 6: Implement recover-then-reconcile-then-start**

`start_workers/1` must require the safe base phase, refuse existing unsafe Oban, call
`Recovery.recover_orphans(startup?: true, now: now)`, call
`DeferredWorker.reconsider_due(workflow: :dry_run, now: now, settings: settings)`, then start exact
serial queues. Map internal failures to `:startup_recovery_failed` or
`:deferred_reconciliation_failed`.

- [ ] **Step 7: Run runtime tests and commit**

Run the focused test file until green, then:

```bash
git add lib/context_bot/dry_run/runtime.ex test/context_bot/dry_run/runtime_test.exs
git commit -m "Split dry-run startup from worker catch-up"
```

---

### Task 4: CLI Attachment and Catch-up Ordering

**Files:**
- Modify: `test/mix/tasks/context_bot.dry_run_test.exs`
- Modify: `lib/mix/tasks/context_bot.dry_run.ex`

**Interfaces:**
- Consumes: `DryRun.prepare/3`, `Runtime.ensure_application_started/0`, and `Runtime.start_workers/1`.
- CLI output adds exactly one line: `dry_run_disposition=created|attached`.

- [ ] **Step 1: Update fakes and write failing ordering tests**

Make the test runtime expose both phases and the service expose `prepare/3`. Assert mailbox ordering
by receiving:

```elixir
assert_received :base_application_started
assert_received {:prepare, post, question, []}
assert_received :workers_started
assert_received {:await, 42, _options}
```

Add a test whose service returns `{:ok, invocation, :attached}` and assert the shell contains one
`dry_run_id=42` line and one `dry_run_disposition=attached` line without question/target leakage.

- [ ] **Step 2: Run Mix task tests and verify RED**

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.dry_run_test.exs
```

Expected: failures because the task still starts workers before always-new creation.

- [ ] **Step 3: Implement the ordered task flow**

Change `run/1` to:

```elixir
validate_runtime!(settings)
ensure_application_started!(runtime)
{invocation, disposition} = prepare!(service, post, question)
print_identity(invocation, disposition)
progress = progress_module.start(invocation, anthropic_timeout_ms: settings.anthropic_http_timeout_ms)
token = install_interrupts!(interrupts, progress_module, progress)
start_workers!(runtime)
```

Retain existing await, progress, safe terminal output, signal cleanup, and runtime stop behavior. If
worker startup fails after selection, finish progress/remove handlers and return a finite safe Mix
error; durable state remains available for later catch-up.

- [ ] **Step 4: Run task and integration tests and commit**

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.dry_run_test.exs test/context_bot/dry_run_workflow_test.exs
```

Then:

```bash
git add lib/mix/tasks/context_bot.dry_run.ex test/mix/tasks/context_bot.dry_run_test.exs
git commit -m "Catch up pending work when running dry-run command"
```

---

### Task 5: Verification, Review, Integration, and Safe Duplicate Cleanup

**Files:**
- Modify if warranted: `knowledge-base/reports/2026-08-10-elixir-cli-signals.md`
- Modify if warranted: `knowledge-base/learnings.md`
- Database after integration: `data/context_bot_dev.db`

**Interfaces:**
- Consumes the complete tested implementation.
- Produces a clean, reviewed main branch and a live development database with invocation 2 safely terminalized and invocation 3 untouched.

- [ ] **Step 1: Run focused regression tests**

```bash
direnv exec . just test test/context_bot/workflow/store_test.exs test/context_bot/dry_run_test.exs test/context_bot/workers/deferred_worker_test.exs test/context_bot/dry_run/runtime_test.exs test/mix/tasks/context_bot.dry_run_test.exs test/context_bot/dry_run_workflow_test.exs
```

Expected: all pass, with no real AppView or Anthropic traffic.

- [ ] **Step 2: Run the full verification gate**

```bash
direnv exec . just check
```

Expected: ExUnit, shell tests, formatting, Credo, ShellCheck, and Dialyzer all pass.

- [ ] **Step 3: Request independent code review and address findings**

Use `superpowers:requesting-code-review`, review the complete branch diff against the approved
design, and fix every Critical or Important issue test-first.

- [ ] **Step 4: Integrate linearly into main**

Use `superpowers:finishing-a-development-branch`. Rebase if main advanced, re-run `just check`, then
fast-forward main without a merge commit as previously authorized by the user.

- [ ] **Step 5: Inspect duplicate targets read-only on main**

Before mutation, query invocation IDs 2 and 3 plus their incomplete job IDs and confirm both still
match the expected target/question and invocation 3 remains nonterminal. Abort cleanup if those
preconditions do not hold.

- [ ] **Step 6: Terminalize only invocation 2 in one immediate SQLite transaction**

Use an application Mix task or `Ecto.Adapters.SQL.query!` through `mix run --no-start` to set:

```elixir
%{
  status: :failed,
  stage: :failed,
  failure_category: :invalid_input,
  failure_detail: %{"reason" => "superseded_duplicate_dry_run"},
  completed_at: DateTime.utc_now()
}
```

Cancel only incomplete Oban jobs whose args identify invocation 2. Do not start the application,
Oban, AppView requests, or Anthropic. Preserve invocation 3 and all historical rows.

- [ ] **Step 7: Verify cleanup and report**

Read back IDs 2 and 3 and job state metadata. Confirm invocation 2 is terminal with cancelled jobs,
invocation 3 is unchanged and pending, and no provider budget entry was added. Report that the next
matching `just dry-run` will attach to invocation 3 and process all safe pending dry work.
