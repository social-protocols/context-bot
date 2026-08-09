# Local read-only dry run

**Date:** 2026-08-09

## Goal

Provide an operator command that exercises the durable Context Bot workflow before a bot account
exists. Given a public Bluesky post and a question, the command creates a synthetic local reply,
fetches the post and its ancestor chain, calls Anthropic, stores the complete result in local
SQLite, and prints the proposed reply.

The run is read-only with respect to Bluesky. It may perform public AppView reads and paid
Anthropic requests, but it must never authenticate to a PDS, poll notifications, or publish an
ATProto record.

The operator interface is:

```bash
just dry-run <bluesky-post-url-or-at-uri> "What's the context?"
```

## Scope

The dry run must exercise the production-shaped durable path:

- SQLite workflow checkpoints and Oban jobs;
- public thread retrieval and ancestor-only canonicalization;
- Anthropic prompt construction, server-side research, retries, and reply validation;
- daily budget reservation and settlement;
- complete provider-response retention; and
- safe terminal failure recording.

It deliberately skips:

- notification polling and mention validation;
- Bluesky Elder, team, and operator-allowlist eligibility;
- actor and global mention-rate admission;
- ATProto session creation or refresh;
- reply-record construction and all repository reads or writes; and
- Fly deployment or any other remote mutation.

## Durable invocation state

Add a non-null `dry_run` boolean to invocations with a database default of `false`. Existing and
future public mention rows therefore retain their current behavior without migration backfill
logic. Only the explicit operator command creates a row with `dry_run: true`.

A dry-run row also retains:

- the normalized URI of the real public target post;
- the operator's question;
- a locally generated invocation identity used only for SQLite and Oban idempotency; and
- the same thread, Anthropic, usage, validation, failure, and completion fields used by public
  invocations.

The local invocation URI and CID are opaque local identifiers. They are never submitted to an
ATProto API and must not be mistaken for a published record.

`dry_run` is the durable publication safety boundary. After successful research, a dry-run
invocation transitions directly to `complete` with `selected_reply`, usage, validation, messages,
and response envelopes retained. It never receives a reply repository, rkey, record, URI, CID, or
reply job. Enabling the public bot later cannot make an old dry run publishable.

## Public Bluesky input and reads

The command accepts either:

- `https://bsky.app/profile/<handle-or-did>/post/<rkey>`; or
- `at://<handle-or-did>/app.bsky.feed.post/<rkey>`.

It rejects other hosts, collections, malformed identifiers, fragments, and unexpected path
segments. Handles are resolved through the public AppView identity endpoint so the stored target
is a canonical DID-based AT URI.

A dedicated public AppView client exposes only the unauthenticated reads required by this
workflow: handle resolution and `app.bsky.feed.getPostThread`. It uses the configured, reviewed
`APPVIEW_URL` directly and retains the existing timeout and streamed response-size limits. It has
no session dependency and implements no repository operation.

Thread retrieval requests `depth=0` and the configured bounded `parentHeight`. Dry-run
canonicalization validates the returned target, traverses only nested ancestors, ignores direct
replies and other descendants, and appends the synthetic operator question as the invocation
section. The model context is therefore the real ancestor chain and target post followed by the
local question.

## Workflow and process model

`just dry-run` sources only the requested Anthropic secret, starts the application with public bot
activation disabled, and invokes a Mix task. The task starts a minimal Oban instance for the
thread and research queues. It does not start the reply queue, maintenance cron, notification
poller, or authenticated ATProto session.

The dry-run service atomically inserts the invocation in `capturing_thread` and its thread job.
The existing thread worker selects the public reader and dry-run canonicalization behavior from
the durable `dry_run` flag. Its successful checkpoint atomically makes the research job visible.

The existing research worker and runner then use the same claim fencing, budget ledger, response
storage, server-tool continuation handling, retries, length repair, and reply validation as a
public invocation. The research handoff branches on the persisted flag:

- `dry_run: false` retains the existing frozen-reply and publication-job behavior;
- `dry_run: true` persists the research result and transitions directly to `complete` without
  constructing or enqueueing publication state.

The command waits for its invocation to become `complete`, `failed`, or `deferred_budget`. On
completion it prints the invocation database ID, terminal status, selected reply, and a compact
usage/cost summary. Failures and deferrals print only safe categories and timing; provider bodies,
headers, prompts, and credentials remain in their existing protected storage paths and are not
dumped to the terminal.

Oban jobs and committed checkpoints survive interruption. Starting a later dry-run command
against the same database also starts the minimal queues, allowing earlier queued or retrying dry
runs to continue. Each command creates a new invocation so operators can repeat the same question
for comparison; the printed database ID distinguishes runs.

## Budget and configuration

Eligibility and mention-rate limits do not apply because the operator is the invoker. All
Anthropic safeguards do apply, including:

- a required `ANTHROPIC_DAILY_BUDGET_USD` for the command;
- per-attempt reservations and settlement;
- serial research queue execution;
- response and aggregate-storage limits;
- token, tool-use, continuation, retry, and timeout limits; and
- the existing pricing-version validation.

Budget exhaustion uses the existing durable `deferred_budget` state and performs no unreserved
request. The command reports the deferral and exits without silently raising or bypassing the cap.

## Selective secret loading

`secrets.sh` accepts an explicit list of requested names from its fixed allowlist:

- `FLY_API_TOKEN`;
- `SECRET_KEY_BASE`;
- `BOT_APP_PASSWORD`; and
- `ANTHROPIC_API_KEY`.

It keeps its all-or-nothing behavior for the requested subset, cleans temporary values, preserves
shell tracing behavior, and never prints values. Missing unrequested fields do not matter.

`just dry-run` requests only `ANTHROPIC_API_KEY`. `just deploy` explicitly requests all four
deployment secrets and retains its current staged-secret behavior. Runtime configuration accepts
an Anthropic key while `BOT_ENABLED=false`, but it still requires bot identity and bot credentials
only when the public bot is enabled.

## Failure behavior

Invalid operator input fails before inserting a workflow row or making a network request. Once an
invocation exists, unavailable or private posts, malformed or oversized AppView responses,
Anthropic failures, unsafe usage data, budget exhaustion, and storage exhaustion use the existing
finite workflow outcomes wherever they apply.

The command exits nonzero for terminal failure or invalid input. A budget deferral is reported as
a non-successful incomplete run without an Anthropic call. Interrupting the command leaves durable
state intact.

No failure path publishes a fallback post. A defense-in-depth check prevents reply workers from
claiming `dry_run: true` rows even if a malformed or manually inserted reply job exists.

## Testing and acceptance

Behavior-first tests cover:

- Bluesky URL and AT URI normalization, including rejection of lookalike hosts and invalid paths;
- public handle resolution and ancestor-only AppView requests without authorization or proxy
  headers;
- selective `secrets.sh` loading and cleanup for both dry-run and deploy subsets;
- atomic dry-run insertion at thread capture with no eligibility job;
- synthetic canonical context containing ancestors, target, and question but no descendants;
- the same budget reservation, response retention, retry, and repair behavior as public research;
- budget exhaustion before an Anthropic request;
- interruption and retry from durable jobs;
- successful direct transition from research to `complete`;
- terminal failure reporting without sensitive output; and
- defense-in-depth rejection of publication for dry-run rows.

An end-to-end test uses mocked public AppView and Anthropic responses through the actual SQLite and
Oban pipeline. It asserts that the selected reply and full provider envelope are stored while no
ATProto session, eligibility lookup, notification poll, repository read/write, reply record, or
reply job occurs.

Manual acceptance runs `just dry-run` against a real public post with a real Anthropic key. Success
means the command prints a conforming proposed reply, the SQLite row reaches `complete`, the
ancestor chain and provider evidence are retained, the daily budget ledger is settled, and no
Bluesky account or PDS write credential exists anywhere in the process.
