# Local Live Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `just live-run <invocation-url>` to durably process one operator-selected public
Bluesky mention and publish exactly one reply as the configured bot without deployment or mention
polling.

**Architecture:** A live-run adapter resolves and validates the selected invocation, then atomically
creates or attaches to a public `invocations` row in an isolated `data/live-demo.db`. A guarded local
runtime starts the existing `thread`, `research`, and `reply` Oban queues plus the authenticated
ATProto session, while the Mix task owns progress, interruption, resumption, and terminal output.
Production polling and eligibility remain unchanged.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix 1.8, Ecto/SQLite, Oban Lite, Req, ExUnit,
Bash, Just, Devbox, direnv

## Global Constraints

- Run every command through `direnv exec .` from the isolated worktree.
- Keep `BOT_ENABLED=false`; the live command must never start `ContextBot.Mentions.Poller`.
- The supplied URL identifies the invocation post containing the question and direct bot mention.
- Bypass actor eligibility and admission counters only for this explicit command; preserve all
  Anthropic daily-budget reservations and provider limits.
- Fetch the invocation and ancestors with `depth=0`; never include descendant replies.
- Use the existing public `ThreadWorker` → `ResearchWorker` → `ReplyWorker` implementation and its
  deterministic ATProto write reconciliation.
- Use `data/live-demo.db` by default and reject the normal development, test, or production database
  path.
- Permit at most one nonterminal invocation in the live-demo database.
- Repeating an invocation URI attaches to the same row regardless of a changed CID and never creates
  or publishes a second reply.
- Automated tests use fake HTTP/session boundaries and never publish to Bluesky or spend Anthropic
  budget.
- Preserve the user-owned `devbox.json` and `devbox.lock` changes on `main`.

---

### Task 1: Resolve and Validate the Selected Public Invocation

**Files:**
- Create: `lib/context_bot/live_run/invocation_post.ex`
- Create: `test/context_bot/live_run/invocation_post_test.exs`
- Reuse: `lib/context_bot/dry_run/post_reference.ex`
- Reuse: `lib/context_bot/atproto/public_client.ex`
- Reuse: `lib/context_bot/mentions/validator.ex`

**Interfaces:**
- Consumes: `ContextBot.DryRun.PostReference.normalize/2`,
  `ContextBot.ATProto.PublicClient.get_post_thread/2`, and
  `ContextBot.Mentions.Validator.validate/2`.
- Produces: `ContextBot.LiveRun.InvocationPost.resolve/2` and
  `ContextBot.LiveRun.InvocationPost.fetch/3`.
- `resolve(reference, resolver) :: {:ok, at_uri} | {:error, term}`.
- `fetch(at_uri, settings, options) :: {:ok, receipt} | {:error, term}` where `receipt` contains
  `uri`, `cid`, `actor_did`, `actor_handle`, `invocation_text`, and `raw`.

- [ ] **Step 1: Write failing resolver and validation tests**

Create table-driven tests that cover a handle URL, DID AT URI, wrong target URI, blocked/not-found
views, malformed selected views, self-authorship, missing/wrong mention facets, invalid facet byte
ranges, and a mention-only post. The successful fixture must include UTF-8 text so removal uses
ATProto byte offsets rather than grapheme indexes:

```elixir
test "returns a bounded operator receipt for a real direct mention" do
  settings = Settings.load(bot_did: @bot_did, thread_parent_height: 80)
  body = invocation_thread("@getcontext.bot ¿Qué falta?", mention_range(0, 15, @bot_did))
  Application.put_env(:context_bot, StubClient, response: {:ok, 200, %{}, body})

  assert {:ok, receipt} =
           InvocationPost.fetch(@invocation_uri, settings,
             client: StubClient
           )

  assert receipt.uri == @invocation_uri
  assert receipt.cid == "bafy-invocation"
  assert receipt.actor_did == "did:plc:actor"
  assert receipt.invocation_text == "¿Qué falta?"
  assert receipt.raw["source"] == "local_live_demo"
  assert receipt.raw["post"]["record"] == body["thread"]["post"]["record"]
end

test "rejects a post whose only text is the bot mention" do
  settings = Settings.load(bot_did: @bot_did, thread_parent_height: 80)
  body = invocation_thread("@getcontext.bot", mention_range(0, 15, @bot_did))
  Application.put_env(:context_bot, StubClient, response: {:ok, 200, %{}, body})

  assert {:error, :missing_question} =
           InvocationPost.fetch(@invocation_uri, settings, client: StubClient)
end
```

Define the test boundary and facet helper in the same test module:

```elixir
defmodule StubClient do
  def get_post_thread(_uri, _parent_height) do
    Application.fetch_env!(:context_bot, __MODULE__)[:response]
  end
end

defp mention_range(first, last, did) do
  %{
    "index" => %{"byteStart" => first, "byteEnd" => last},
    "features" => [%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}]
  }
end

defp invocation_thread(text, facet) do
  %{
    "thread" => %{
      "$type" => "app.bsky.feed.defs#threadViewPost",
      "post" => %{
        "uri" => @invocation_uri,
        "cid" => "bafy-invocation",
        "author" => %{"did" => "did:plc:actor", "handle" => "actor.test"},
        "record" => %{
          "$type" => "app.bsky.feed.post",
          "text" => text,
          "facets" => [facet],
          "createdAt" => "2026-08-11T12:00:00.000Z"
        }
      }
    }
  }
end
```

- [ ] **Step 2: Run the focused test and observe the missing-module failure**

Run:

```bash
direnv exec . just test test/context_bot/live_run/invocation_post_test.exs
```

Expected: compilation fails because `ContextBot.LiveRun.InvocationPost` does not exist.

- [ ] **Step 3: Implement strict resolution, extraction, and mention removal**

Implement the public boundary with dependency injection and reuse the notification validator by
building a validation-only notification from the selected post:

```elixir
def resolve(reference, resolver \\ PublicClient),
  do: PostReference.normalize(reference, resolver)

def fetch(uri, settings, options \\ []) do
  client = Keyword.get(options, :client, PublicClient)

  with {:ok, 200, _headers, body} <-
         client.get_post_thread(uri, settings.thread_parent_height),
       {:ok, post} <- selected_post(body, uri),
       {:ok, validated} <- Validator.validate(validation_notification(post), settings.bot_did),
       {:ok, question} <- question_without_bot_mentions(post["record"], settings.bot_did) do
    {:ok,
     %{
       uri: validated.uri,
       cid: validated.cid,
       actor_did: validated.actor_did,
       actor_handle: validated.actor_handle,
       invocation_text: question,
       raw: %{"source" => "local_live_demo", "post" => post}
     }}
  end
end
```

Validate every mention range as integer UTF-8 byte offsets satisfying
`0 <= byteStart < byteEnd <= byte_size(text)`. Remove all ranges targeting `bot_did` from right to
left, require the remaining binary to be valid UTF-8, normalize whitespace only for
`invocation_text`, and keep the original record unchanged in `raw`. Normalize client errors to the
same finite atoms used by the dry-run boundary.

- [ ] **Step 4: Run and pass the focused tests**

Run:

```bash
direnv exec . just test test/context_bot/live_run/invocation_post_test.exs
```

Expected: all invocation-post tests pass with no external HTTP calls.

- [ ] **Step 5: Commit the validation boundary**

```bash
git add lib/context_bot/live_run/invocation_post.ex test/context_bot/live_run/invocation_post_test.exs
git commit -m "feat: validate manual live invocations"
```

---

### Task 2: Add Atomic Live-Run Receipt Idempotency

**Files:**
- Modify: `lib/context_bot/workflow/store.ex`
- Modify: `test/context_bot/workflow/store_test.exs`

**Interfaces:**
- Consumes: the receipt map from `InvocationPost.fetch/3` and a thread-job builder.
- Produces:
  `ContextBot.Workflow.Store.create_or_attach_live_run/3 ::
  {:ok, Invocation.t(), :created | :attached | :complete | :terminal} |
  {:error, :active_invocation, %{id: pos_integer(), uri: String.t()}} |
  {:error, :contradictory_invocations, [pos_integer()]} | {:error, :invalid_input}`.
- The third argument is `(uri, cid -> Ecto.Changeset.t())`, allowing tests to inspect exact atomic
  job insertion.

- [ ] **Step 1: Write failing transaction and idempotency tests**

Add tests for atomic row/job insertion, same-URI attachment, changed-CID attachment, completed-row
reporting, failed-row reporting, rollback on an invalid job, a different active invocation, and
contradictory same-URI rows:

```elixir
test "attaches by URI after an edit and never inserts another thread job" do
  receipt = live_receipt(@uri, "bafy-one")

  assert {:ok, first, :created} =
           Store.create_or_attach_live_run(receipt, @received_at, &live_thread_job/2)

  edited = %{receipt | cid: "bafy-two"}

  assert {:ok, attached, :attached} =
           Store.create_or_attach_live_run(edited, @received_at, &live_thread_job/2)

  assert attached.id == first.id
  assert attached.notification_cid == "bafy-one"
  assert Repo.aggregate(Invocation, :count) == 1
  assert Repo.aggregate(Oban.Job, :count) == 1
end

test "refuses a second active live demo before inserting anything" do
  {:ok, active, :created} =
    Store.create_or_attach_live_run(live_receipt(@uri, "bafy-one"), @received_at, &live_thread_job/2)

  assert {:error, :active_invocation, %{id: active.id, uri: @uri}} =
           Store.create_or_attach_live_run(
             live_receipt(@other_uri, "bafy-two"),
             @received_at,
             &live_thread_job/2
           )
end
```

Define `live_receipt/2` as a complete valid map in `StoreTest`:

```elixir
defp live_receipt(uri, cid) do
  %{
    uri: uri,
    cid: cid,
    actor_did: "did:plc:actor",
    actor_handle: "actor.test",
    invocation_text: "What is missing?",
    raw: %{"source" => "local_live_demo", "post" => %{"uri" => uri, "cid" => cid}}
  }
end

defp live_thread_job(uri, cid) do
  Oban.Job.new(%{"uri" => uri, "cid" => cid},
    worker: ContextBot.Workers.ThreadWorker,
    queue: :thread
  )
end
```

- [ ] **Step 2: Run the focused Store test and observe the undefined-function failure**

Run:

```bash
direnv exec . just test test/context_bot/workflow/store_test.exs
```

Expected: the new tests fail because `create_or_attach_live_run/3` is undefined.

- [ ] **Step 3: Implement the immediate transaction**

Add a bounded validator and an immediate transaction that locks the decision, rejects more than one
same-URI row, checks for a different nonterminal row, and creates the public invocation directly at
`capturing_thread`:

```elixir
attrs = %{
  dry_run: false,
  invocation_text: receipt.invocation_text,
  invocation_uri: receipt.uri,
  notification_cid: receipt.cid,
  current_cid: receipt.cid,
  actor_did: receipt.actor_did,
  actor_handle: receipt.actor_handle,
  raw_notification: receipt.raw,
  received_at: received_at,
  status: :capturing_thread,
  stage: :capturing_thread,
  eligibility_method: "operator_live_demo",
  eligibility_evidence: %{"source" => "explicit_local_command"},
  admitted_at: received_at
}
```

Insert the invocation and `thread` queue job in the same transaction. Treat `complete`, `failed`,
and `ineligible` as terminal. Never mutate the identity or create a new row when a URI already
exists, regardless of current CID.

- [ ] **Step 4: Pass Store tests and the existing dry/public receipt tests**

Run:

```bash
direnv exec . just test test/context_bot/workflow/store_test.exs
direnv exec . just test test/context_bot/dry_run_test.exs
direnv exec . just test test/context_bot/poc_workflow_test.exs
```

Expected: all focused tests pass; existing URI/CID production ingestion behavior is unchanged.

- [ ] **Step 5: Commit the durable receipt path**

```bash
git add lib/context_bot/workflow/store.ex test/context_bot/workflow/store_test.exs
git commit -m "feat: persist idempotent live demo receipts"
```

---

### Task 3: Build the Isolated Authenticated Worker Runtime

**Files:**
- Create: `lib/context_bot/live_run/runtime.ex`
- Create: `test/context_bot/live_run/runtime_test.exs`
- Modify: `lib/context_bot/workflow/store.ex`
- Modify: `test/context_bot/workflow/store_test.exs`
- Reuse: `lib/context_bot/dry_run/runtime_owner.ex`
- Reuse: `lib/context_bot/workflow/recovery.ex`

**Interfaces:**
- Produces `ContextBot.LiveRun.Runtime.configure_and_start/2`, `try_acquire_owner/1`,
  `authenticate/2`, `start_workers/3`, and `stop/2`.
- Produces `ContextBot.Workflow.Store.resume_due_live_budget/3` for exact, operator-authorized budget
  resumption without eligibility or rate admission.
- `start_workers/3` receives the selected `%Invocation{}` and invokes only
  `Recovery.recover_invocation/2` for that ID before starting serial `thread`, `research`, and
  `reply` queues.
- `configure_and_start(database_path, options)`, `try_acquire_owner(database_path)`,
  `authenticate(owner, options)`, `start_workers(owner, invocation, options)`, and
  `stop(owner, options)` use the argument order shown here in production and tests.
- `Store.resume_due_live_budget(invocation, now, job_builder)` accepts a `%DateTime{}` and a
  `(uri, cid -> Ecto.Changeset.t())` research-job builder.

- [ ] **Step 1: Write failing database, session, queue, and recovery tests**

Cover path expansion, rejection of `context_bot_dev.db`, test DB, `DATABASE_PATH`, `:memory:`, and
the current configured Repo path; parent-directory creation; migrations; `BOT_ENABLED=true`
rejection; missing bot identity/password/budget rejection; DID mismatch; exact-invocation recovery;
one-active-invocation enforcement; exact serial queues; no plugins; no poller; shutdown ordering; and
lock retention after shutdown failure.

```elixir
test "starts only authenticated thread research and reply processing" do
  invocation = live_invocation!(:capturing_thread)
  configure_owner({:ok, self()})
  configure_session({:ok, "access-token"})

  assert :ok = Runtime.authenticate(self(), owner: FakeOwner, session: FakeSession)

  assert :ok =
           Runtime.start_workers(self(), invocation,
             owner: FakeOwner,
             recovery: FakeRecovery
           )

  assert_receive {:recover_exactly, ^invocation, [startup?: true]}
  assert Enum.sort(Keyword.keys(Oban.config(Oban).queues)) == [:reply, :research, :thread]
  refute Process.whereis(ContextBot.Mentions.Poller)
end
```

Define `FakeOwner`, `FakeSession`, and `FakeRecovery` as small application-configured modules in the
test file. `FakeOwner.owned?/1` returns the configured boolean; `FakeSession.start_link/1` starts an
Agent registered under the requested name and `access_token/0` returns the configured result;
`FakeRecovery.recover_invocation/2` sends `{:recover_exactly, invocation, options}` to the configured
test PID and returns `:unchanged`. Define `live_invocation!/1` by inserting a valid `dry_run: false`
`Invocation` with `eligibility_method: "operator_live_demo"` and the requested stage.

```elixir
defmodule FakeOwner do
  def acquire(_options), do: Application.fetch_env!(:context_bot, __MODULE__)[:result]
  def owned?(_owner), do: true
  def release(_owner), do: :ok
end

defmodule FakeSession do
  def start_link(options), do: Agent.start_link(fn -> :session end, name: options[:name])
  def access_token, do: Application.fetch_env!(:context_bot, __MODULE__)[:result]
end

defmodule FakeRecovery do
  def recover_invocation(invocation, options) do
    send(Application.fetch_env!(:context_bot, __MODULE__)[:test_pid], {
      :recover_exactly,
      invocation,
      options
    })

    :unchanged
  end
end

defp configure_owner(result),
  do: Application.put_env(:context_bot, FakeOwner, result: result)

defp configure_session(result),
  do: Application.put_env(:context_bot, FakeSession, result: result)

defp live_invocation!(stage) do
  %Invocation{}
  |> Invocation.changeset(%{
    dry_run: false,
    invocation_uri: "at://did:plc:actor/app.bsky.feed.post/3demo",
    notification_cid: "bafy-demo",
    current_cid: "bafy-demo",
    actor_did: "did:plc:actor",
    raw_notification: %{"source" => "local_live_demo"},
    received_at: DateTime.utc_now(),
    eligibility_method: "operator_live_demo",
    eligibility_evidence: %{"source" => "explicit_local_command"},
    admitted_at: DateTime.utc_now(),
    status: stage,
    stage: stage
  })
  |> Repo.insert!()
end
```

Add Store tests proving that only a due `deferred_budget` row with
`eligibility_method == "operator_live_demo"` can transition atomically to `thread_ready` with one
research job; a future deferral and normal public invocation remain unchanged.

- [ ] **Step 2: Run focused tests and observe the missing runtime/API failures**

Run:

```bash
direnv exec . just test test/context_bot/live_run/runtime_test.exs
direnv exec . just test test/context_bot/workflow/store_test.exs
```

Expected: failures identify the missing `LiveRun.Runtime` and `resume_due_live_budget/3` interfaces.

- [ ] **Step 3: Implement safe database configuration and migration**

Before starting `:context_bot`, read the requested path, resolve it against the repository root,
compare its real expanded path with every forbidden configured path, create only its parent
directory, replace only `ContextBot.Repo[:database]`, and migrate it:

```elixir
repo_config = Application.fetch_env!(:context_bot, ContextBot.Repo)
Application.put_env(:context_bot, ContextBot.Repo, Keyword.put(repo_config, :database, database))

{:ok, _migrated, _apps} =
  Ecto.Migrator.with_repo(ContextBot.Repo, fn repo ->
    Ecto.Migrator.run(repo, :up, all: true)
  end)
```

Store the validated `BOT_APP_PASSWORD` in application config immediately before starting the
session. Do not log it. Then call `Application.ensure_all_started(:context_bot)` and verify that no
Oban, session, or poller was started by the disabled base application.

- [ ] **Step 4: Implement owner fencing, eager authentication, exact recovery, and queues**

Reuse `ContextBot.DryRun.RuntimeOwner` with the live database path so the file lock is database
scoped. Start `ContextBot.ATProto.Session` explicitly and call `access_token/0` before receipt
creation. The existing session verifies the authenticated DID against `BOT_DID`.

Under verified ownership, reload the selected invocation, reject any other nonterminal row, call
`Store.resume_due_live_budget/3` when applicable, call
`Recovery.recover_invocation(invocation, startup?: true)`, recheck ownership/invariants, and start:

```elixir
options =
  :context_bot
  |> Application.fetch_env!(Oban)
  |> Keyword.put(:queues, thread: 1, research: 1, reply: 1)
  |> Keyword.put(:plugins, [])
  |> Keyword.delete(:testing)

Oban.start_link(options)
```

Shutdown pauses queues, waits the configured grace period, stops the session, and releases the file
lock only after both worker and session shutdown are confirmed.

- [ ] **Step 5: Pass runtime, recovery, and publication safety tests**

Run:

```bash
direnv exec . just test test/context_bot/live_run/runtime_test.exs
direnv exec . just test test/context_bot/workflow/store_test.exs
direnv exec . just test test/context_bot/workflow/recovery_test.exs
direnv exec . just test test/context_bot/workers/reply_worker_test.exs
```

Expected: tests pass; `dry_run=true` remains nonpublishable and normal production recovery is
unchanged.

- [ ] **Step 6: Commit the isolated runtime**

```bash
git add lib/context_bot/live_run/runtime.ex lib/context_bot/workflow/store.ex \
  test/context_bot/live_run/runtime_test.exs test/context_bot/workflow/store_test.exs
git commit -m "feat: add isolated live demo runtime"
```

---

### Task 4: Add the Durable Live-Run Service and Progress Renderer

**Files:**
- Create: `lib/context_bot/live_run.ex`
- Create: `lib/context_bot/live_run/progress.ex`
- Create: `test/context_bot/live_run_test.exs`
- Create: `test/context_bot/live_run/progress_test.exs`
- Reuse: `lib/context_bot/dry_run/interrupts.ex`

**Interfaces:**
- Produces `ContextBot.LiveRun.resolve/2`, `prepare/2`, `find/1`, and `await/2`.
- Produces `ContextBot.LiveRun.reply_url/2` for a completed reply URI and configured bot handle.
- Produces the same progress callbacks as `ContextBot.DryRun.Progress`: `start/2`, `update/2`,
  `tick/1`, and `finish/1`.

- [ ] **Step 1: Write failing service and progress tests**

Test successful resolution/preparation, active-conflict propagation, same-URI lookup, completion,
failure, budget deferral, timeout, interruption, stage-only callbacks, safe URL rendering, invalid
stored reply URIs, and content-free progress including publication:

```elixir
test "await reports a completed public reply" do
  invocation = insert_live_invocation!(:complete, reply_uri: @reply_uri)
  assert {:ok, settled} = LiveRun.await(invocation, timeout_ms: 0)
  assert settled.id == invocation.id
  assert LiveRun.reply_url(settled, "getcontext.bot") ==
           {:ok, "https://bsky.app/profile/getcontext.bot/post/3reply"}
end

test "progress never renders stored question or answer content" do
  {:ok, io} = StringIO.open("")
  invocation = %Invocation{
    id: 42,
    dry_run: false,
    stage: :publishing,
    invocation_text: "private question",
    selected_reply: "private answer"
  }

  state = Progress.start(invocation, io: io, tty?: false)
  assert output(io) =~ "live_run_id=42 stage=publishing"
  refute output(io) =~ "private question"
  refute output(io) =~ "private answer"
  assert :ok = Progress.finish(state)
end
```

Define `insert_live_invocation!/2` with the complete set of required receipt fields and merge only
the supplied transition attributes:

```elixir
defp insert_live_invocation!(stage, attrs \\ []) do
  base = %{
    dry_run: false,
    invocation_uri: @invocation_uri,
    notification_cid: "bafy-invocation",
    current_cid: "bafy-invocation",
    actor_did: "did:plc:actor",
    raw_notification: %{"source" => "local_live_demo"},
    received_at: DateTime.utc_now(),
    status: stage,
    stage: stage
  }

  %Invocation{}
  |> Invocation.changeset(Map.merge(base, Map.new(attrs)))
  |> Repo.insert!()
end

defp output(io) do
  {_input, rendered} = StringIO.contents(io)
  rendered
end
```

- [ ] **Step 2: Run focused tests and observe missing-module failures**

Run:

```bash
direnv exec . just test test/context_bot/live_run_test.exs
direnv exec . just test test/context_bot/live_run/progress_test.exs
```

Expected: both files fail until the service and renderer exist.

- [ ] **Step 3: Implement resolution, preparation, lookup, waiting, and reply URLs**

Use `InvocationPost` and `Store` without starting workers:

```elixir
def prepare(uri, options \\ []) do
  settings = Keyword.get(options, :settings, Application.fetch_env!(:context_bot, :settings))
  now = Keyword.get(options, :now, &DateTime.utc_now/0)

  with {:ok, receipt} <- InvocationPost.fetch(uri, settings, options) do
    Store.create_or_attach_live_run(receipt, now.(), &thread_job/2)
  end
end
```

`find/1` returns exactly one same-URI row, `nil`, or `{:error, :contradictory_invocations}`. `await/2`
accepts only `dry_run: false`, reloads by ID, calls `on_update` only when the stage changes, and
returns `{:ok, invocation}`, `{:deferred, invocation}`, `{:error, invocation}`, or finite timeout/
interruption/not-found errors. Parse the stored reply AT URI with `ATURI.parse/1` and render the
configured handle plus rkey; never trust a free-form URL from stored content.

- [ ] **Step 4: Implement content-free live progress**

Mirror the tested dry-run TTY/non-TTY behavior with the `live_run_id` prefix and descriptions for
`capturing_thread`, `thread_ready`, `researching`, `reply_ready`, `publishing`, `deferred_budget`,
`complete`, and `failed`. Do not inspect `invocation_text`, `selected_reply`, thread, provider, or
record fields.

- [ ] **Step 5: Run and pass service/progress tests**

Run:

```bash
direnv exec . just test test/context_bot/live_run_test.exs
direnv exec . just test test/context_bot/live_run/progress_test.exs
```

Expected: all tests pass with deterministic non-TTY output and no content leakage.

- [ ] **Step 6: Commit the service layer**

```bash
git add lib/context_bot/live_run.ex lib/context_bot/live_run/progress.ex \
  test/context_bot/live_run_test.exs test/context_bot/live_run/progress_test.exs
git commit -m "feat: observe durable live demo workflows"
```

---

### Task 5: Add the One-Shot Mix Command

**Files:**
- Create: `lib/mix/tasks/context_bot.live_run.ex`
- Create: `test/mix/tasks/context_bot.live_run_test.exs`

**Interfaces:**
- Produces `mix context_bot.live_run <invocation-url>`.
- Consumes `LiveRun`, `LiveRun.Runtime`, `LiveRun.Progress`, and
  `ContextBot.DryRun.Interrupts` through injectable application configuration.

- [ ] **Step 1: Write failing command orchestration tests**

Use fake service/runtime/progress/interrupt modules, following the existing dry-run Mix-task test
pattern. Verify exact arity, validation before state, base application setup, URL resolution before
locking, owner authentication before `prepare`, worker startup after receipt creation, contention
observation/takeover, successful output, complete-row no-op, failed/deferred output, interrupt
cleanup, malformed dependency results, and secret-free errors.

```elixir
assert [
         {:configure_and_start, database},
         {:resolve, post},
         {:owner_acquire, database},
         {:authenticate, owner},
         {:prepare, uri},
         {:workers_started, owner, 42},
         {:await, 42, await_options},
         {:runtime_stopped, owner}
       ] = Events.all()

assert output =~ "mode=live_public_reply"
assert output =~ "bot_did=did:plc:contextbot"
assert output =~ "invocation_uri=#{uri}"
assert output =~ "status=complete"
assert output =~ "reply_url=https://bsky.app/profile/getcontext.bot/post/3reply"
```

- [ ] **Step 2: Run the command test and observe the missing-task failure**

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.live_run_test.exs
```

Expected: compilation fails because `Mix.Tasks.ContextBot.LiveRun` does not exist.

- [ ] **Step 3: Implement validation and owner flow**

Use `@requirements ["app.config"]`. Require `BOT_ENABLED=false`, a positive daily budget, nonempty
`BOT_DID`, `BOT_HANDLE`, `BOT_PDS_URL`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY`. Read
`CONTEXT_BOT_LIVE_DATABASE_PATH`, default it to `data/live-demo.db`, then call the runtime to validate,
migrate, and start the base application.

Resolve the URL before attempting ownership. An owner must authenticate before calling
`LiveRun.prepare/2`. Print the live-mode warning, bot DID, resolved URI, invocation ID, and disposition
before workers start. A `:complete` disposition skips session/worker startup when the stored reply is
already available.

- [ ] **Step 4: Implement contention, progress, interruption, and terminal output**

Adapt the existing dry-run foreground task loop. While the lock is contended, poll `LiveRun.find/1`
and retry ownership. If the row appears, observe it; if the owner exits before creating the row,
acquire ownership and continue the authenticated preparation path. On `SIGINT`/`SIGTERM`, stop the
await task, stop owned runtime components, clear progress, and print:

```text
status=interrupted
live_run_id=42
```

Map completion, deferral, and terminal failure to finite output. Never print the selected reply,
stored records, raw provider errors, or credentials. A successful public write prints only the safe
reply URL and usage/cost summary.

- [ ] **Step 5: Run and pass the command tests**

Run:

```bash
direnv exec . just test test/mix/tasks/context_bot.live_run_test.exs
```

Expected: all owner, observer, interruption, and output tests pass.

- [ ] **Step 6: Commit the Mix task**

```bash
git add lib/mix/tasks/context_bot.live_run.ex test/mix/tasks/context_bot.live_run_test.exs
git commit -m "feat: add one-shot live demo command"
```

---

### Task 6: Add the Signal-Safe Wrapper and Just Recipe

**Files:**
- Create: `live-run.sh`
- Create: `test/live_run_wrapper_test.sh`
- Modify: `justfile`
- Modify: `test/secrets_test.sh`

**Interfaces:**
- Produces `just live-run <invocation-url>`.
- Loads exactly `BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY` from `secrets.sh`.
- Exports `BOT_ENABLED=false`, `CONTEXT_BOT_LIVE_RUN=true`, and
  `CONTEXT_BOT_LIVE_DATABASE_PATH` only to the Mix child.

- [ ] **Step 1: Write the failing shell-wrapper tests**

Copy the race-aware structure from `test/dry_run_wrapper_test.sh`, but assert one positional
argument, two requested secrets, exact environment, default/overridden database path, exact argument
forwarding, SIGINT-to-SIGTERM translation, repeated-signal cleanup, launch-race child reaping, and no
secret leakage:

```bash
[[ "$(<"$context_bot_test_tmp/arguments")" ==
  "context_bot.live_run https://bsky.app/profile/actor.test/post/3abc" ]] ||
  fail "live-run arguments were not forwarded exactly"
[[ "$(<"$context_bot_test_tmp/bot-enabled")" == "false" ]] ||
  fail "live run enabled the notification poller"
[[ "$(<"$context_bot_test_tmp/live-database")" == "data/live-demo.db" ]] ||
  fail "live run did not select the isolated database"
```

- [ ] **Step 2: Run the shell test and observe the missing-wrapper failure**

Run:

```bash
direnv exec . bash test/live_run_wrapper_test.sh
```

Expected: the test fails because `live-run.sh` does not exist.

- [ ] **Step 3: Implement the wrapper and recipe**

Create a strict one-argument wrapper modeled on `dry-run.sh`:

```bash
source ./secrets.sh BOT_APP_PASSWORD ANTHROPIC_API_KEY

ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +B i" \
  BOT_ENABLED=false \
  CONTEXT_BOT_LIVE_RUN=true \
  CONTEXT_BOT_LIVE_DATABASE_PATH="${CONTEXT_BOT_LIVE_DATABASE_PATH:-data/live-demo.db}" \
  mix context_bot.live_run "$1" &
```

Retain the existing signal-forwarding and child-reaping behavior. Add:

```just
live-run invocation_url:
    ./live-run.sh {{quote(invocation_url)}}
```

Include the new shell files in `just test`, `just format`, `just format-check`, and `just lint`.

- [ ] **Step 4: Pass shell, Just, formatting, and lint tests**

Run:

```bash
direnv exec . bash test/live_run_wrapper_test.sh
direnv exec . bash test/secrets_test.sh
direnv exec . just --dry-run live-run 'https://bsky.app/profile/actor.test/post/3abc'
direnv exec . just format
direnv exec . just lint
```

Expected: wrapper tests pass, the dry-run recipe prints one safely quoted command, ShellCheck passes,
and no secret value appears.

- [ ] **Step 5: Commit the operator entry point**

```bash
git add live-run.sh test/live_run_wrapper_test.sh test/secrets_test.sh justfile
git commit -m "feat: expose safe local live demo recipe"
```

---

### Task 7: Verify the Full Fake Workflow and Document Operation

**Files:**
- Create: `test/context_bot/live_run_workflow_test.exs`
- Modify: `README.md`
- Modify: `.env.example`
- Modify: `AGENTS.md`

**Interfaces:**
- Verifies the complete fake path through the existing production workers.
- Documents the exact command, required non-secret settings, isolated database, interruption model,
  public-write warning, and idempotent rerun behavior.

- [ ] **Step 1: Write the failing full-workflow test**

Build one fake invocation thread with ancestors and a descendant sentinel. Stub public AppView,
Anthropic, authenticated thread fetch, session, `getRecord`, and `putRecord`. Drive the queued jobs
using `Oban.Testing.perform_job/2` and assert:

```elixir
assert {:ok, invocation, :created} =
         LiveRun.prepare(@invocation_uri, settings: settings, client: PublicClient)
refute invocation.dry_run
assert invocation.eligibility_method == "operator_live_demo"

perform_and_delete!(:thread)
assert Repo.reload!(invocation).canonical_thread =~ "ancestor claim"
refute Repo.reload!(invocation).canonical_thread =~ "DESCENDANT SENTINEL"

perform_and_delete!(:research)
assert Repo.reload!(invocation).stage == :reply_ready
perform_and_delete!(:reply)

assert {:ok, complete} = LiveRun.await(invocation, timeout_ms: 0)
assert complete.reply_uri == @reply_uri
assert_receive {:put_record, @reply_uri}
refute_receive {:put_record, @reply_uri}
assert Repo.aggregate(BudgetEntry, :count) > 0
```

Configure `settings` with the bot DID, handle, PDS, parent height, and positive daily budget. The fake
PDS `put_record/4` sends `{:put_record, returned_uri}` to the test process before returning the
successful response. Define the queue driver exactly as:

```elixir
defp perform_and_delete!(queue) do
  job =
    Oban.Job
    |> where([job], job.queue == ^to_string(queue))
    |> Repo.one!()

  attempted = %{job | attempt: max(job.attempt, 1), attempted_at: DateTime.utc_now()}

  assert :ok =
           Oban.Testing.perform_job(attempted,
             repo: Repo,
             engine: Oban.Engines.Lite,
             testing: :manual
           )

  Repo.delete!(Repo.get!(Oban.Job, job.id))
end
```

Rerun preparation for the same URI with an edited CID and assert disposition `:complete`, no new
row, no new Anthropic request, and no new PDS write. Seed an unrelated terminal row to confirm it is
a harmless no-op. Seed a different nonterminal row in a separate test and confirm preparation fails
before any external model/publication call.

- [ ] **Step 2: Run the workflow test as an integration gate**

Run:

```bash
direnv exec . just test test/context_bot/live_run_workflow_test.exs
```

Expected: the test passes using the interfaces completed in Tasks 1–6. Any failure is a defect in a
named interface from those tasks and must be corrected in that owning file before continuing.

- [ ] **Step 3: Verify the integration introduces no new workflow mechanism**

Inspect `git diff --name-only main...HEAD` and the workflow test assertions. Confirm fake boundaries
use existing worker application configuration, the live receipt reaches `ThreadWorker` as
`dry_run: false`, and the diff adds no worker, queue, status, database migration, or production
poller branch.

- [ ] **Step 4: Pass the full workflow and adjacent regression tests**

Run:

```bash
direnv exec . just test test/context_bot/live_run_workflow_test.exs
direnv exec . just test test/context_bot/poc_workflow_test.exs
direnv exec . just test test/context_bot/dry_run_workflow_test.exs
```

Expected: fake live publication occurs once; production and dry-run workflows remain unchanged.

- [ ] **Step 5: Document the live operator flow**

Add a README section with the exact safe sequence:

```bash
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just live-run 'https://bsky.app/profile/actor.example/post/3abc'
```

State that it publicly replies as the configured `BOT_DID`/`BOT_HANDLE`, the URL must be the direct
mention post, only actor eligibility is bypassed, spend controls remain active, no poller starts,
state lives in `data/live-demo.db`, Ctrl-C leaves resumable work, and rerunning the URL is idempotent.
Add `CONTEXT_BOT_LIVE_DATABASE_PATH=data/live-demo.db` to `.env.example` without adding secrets.
Update the command and architecture tables in `AGENTS.md`.

- [ ] **Step 6: Run the complete verification gate**

Run:

```bash
direnv exec . just format
direnv exec . just check
git diff --check
git status --short
```

Expected: formatting is stable, compilation with warnings-as-errors passes, every ExUnit and shell
test passes, Credo and ShellCheck report no issues, Dialyzer reports zero errors, and only intended
feature files are modified.

- [ ] **Step 7: Commit the verified feature and documentation**

```bash
git add test/context_bot/live_run_workflow_test.exs README.md .env.example AGENTS.md
git commit -m "test: verify local live demo workflow"
```

---

### Task 8: Review and Integrate the Feature Branch

**Files:**
- Review all commits on `codex/live-demo` after `0022a90`.
- Do not modify the user-owned `devbox.json` or `devbox.lock` changes on `main`.

**Interfaces:**
- Produces a reviewed, linearly integrated `main` branch.

- [ ] **Step 1: Review the complete branch diff against the approved spec**

Run:

```bash
git diff --stat main...HEAD
git diff --check main...HEAD
git log --oneline main..HEAD
```

Check direct-mention validation, database isolation, one-active invariant, eager bot authentication,
budget retention, exact recovery, signal behavior, safe output, no-poller startup, and deterministic
single publication.

- [ ] **Step 2: Run a fresh final gate after review fixes**

Run:

```bash
direnv exec . just check
```

Expected: the complete gate passes from fresh output.

- [ ] **Step 3: Rebase and fast-forward without disturbing main's working tree**

From the feature worktree, fetch the current local `main` commit and rebase if it advanced. Then,
from the main checkout, fast-forward only when `git diff --name-only main..codex/live-demo` does not
include `devbox.json` or `devbox.lock`:

```bash
git rebase main
git -C /Users/jwarden/Dropbox/ai-projects/context-bot merge --ff-only codex/live-demo
```

Expected: `main` advances linearly while its pre-existing unstaged Devbox changes remain untouched.

- [ ] **Step 4: Verify integrated state without making a public call**

Run from the main checkout:

```bash
direnv exec . just check
git status --short
```

Expected: the gate passes and `git status` shows only the user's original `devbox.json` and
`devbox.lock` modifications. Do not run `just live-run` until the user supplies the real invocation
URL and explicitly authorizes that public reply.
