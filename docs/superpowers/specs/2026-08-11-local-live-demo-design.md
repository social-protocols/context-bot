# Local Live Demo Design

**Date:** 2026-08-11

## Goal

Add an explicit command-line path that processes one real public Bluesky invocation and publishes
the resulting reply as `@getcontext.bot`, without deploying Context Bot or starting the normal
notification poller.

The operator will use another account to publish a direct mention, then run:

```bash
just live-run 'https://bsky.app/profile/example.bsky.social/post/3example'
```

The URL identifies the invocation post itself: the post containing both the question and the direct
mention of `@getcontext.bot`.

## Product Decisions

- This command performs a real public write. It is not an extension of `just dry-run`.
- It accepts exactly one invocation URL and never polls for other notifications.
- It bypasses actor eligibility only because running the explicit local command is the operator's
  authorization. Normal poller-driven invocations retain the existing Bluesky Elder, `bsky.team`,
  and operator-allowlist rules.
- It retains the existing daily Anthropic budget and all provider request reservations.
- It uses the production ancestor capture, Claude research, reply construction, and idempotent
  ATProto publication code.
- It uses a persistent, isolated SQLite database at `data/live-demo.db` by default. This prevents
  unrelated jobs in the normal development database from running.
- Interrupting the foreground command stops local processing without turning the invocation into a
  terminal failure. Running the same URL again resumes or attaches to the durable workflow.

## Non-Goals

- Polling, ingesting, or acknowledging Bluesky notifications
- Processing more than one manually selected invocation in one command
- Bypassing Anthropic budget controls, response validation, or publication safeguards
- Adding a general operator administration interface
- Publishing audit records, audit blobs, or an audit page
- Changing the behavior of `just dry-run`, the deployed bot, or normal eligibility decisions

## Runtime Isolation

The command runs with `BOT_ENABLED=false`, so the normal application does not start
`ContextBot.Mentions.Poller`, the production Oban supervision tree, or automatic global catch-up.
The command starts only the dependencies needed for the one-shot workflow:

1. `ContextBot.Repo`, configured for the live-demo SQLite file;
2. `ContextBot.Finch`;
3. `ContextBot.ATProto.Session`, with the configured bot identity and app password;
4. a local Oban instance with only the public thread, research, and reply queues; and
5. a foreground observer that reports stage progress and terminal output.

Before starting the runtime, the wrapper creates the database directory and applies all Ecto
migrations. A process-level lock scoped to the absolute live-demo database path prevents two local
commands from owning the same demo runtime concurrently. A second command either attaches to the
owner or exits with a finite, actionable error; it never starts a competing worker set.

The isolated database may contain multiple historical demos, but at most one may be nonterminal. The
command checks that invariant under the database-scoped runtime lock before starting queues. If a
different invocation is active, it exits with that invocation's local ID and URL and instructs the
operator to resume or resolve it first. If the active invocation matches the supplied URL, the
command attaches to it. This makes ordinary Oban queue startup and retry behavior safe without a
parallel demo consuming unrelated work.

`CONTEXT_BOT_LIVE_DATABASE_PATH` may override the default file. Relative paths resolve from the
repository root. The command must reject the normal development, test, or configured production
database path so a live-demo run cannot silently consume unrelated jobs.

## Invocation Resolution and Validation

The command accepts the same Bluesky web URL and AT URI formats supported by the existing post
reference resolver. It resolves a handle to its current DID and obtains the selected post plus its
rootward ancestors from the public AppView with descendant depth zero.

Before any row or job becomes publishable, it validates that:

- the selected view is an available `app.bsky.feed.post`;
- the selected post URI is the resolved invocation URI;
- the post has a nonempty current CID and an author DID other than the configured bot DID;
- the post record contains a rich-text mention facet targeting the configured bot DID; and
- the invocation text is nonempty after the bot mention is removed for operator display.

The command stores a bounded synthetic receipt that is clearly marked with
`source: "local_live_demo"` and contains the fetched post identity and record. It does not claim that
a notification was observed. Existing invocation columns remain sufficient; no new database column
or migration is required.

## Durable Workflow

Receipt creation is atomic and idempotent by invocation URI. The selected post's current CID becomes
the initial notification/current CID used by existing worker lookups. The new receipt starts directly
at `capturing_thread`, records `eligibility_method: "operator_live_demo"`, records bounded evidence,
and atomically enqueues the thread job. It does not call the eligibility worker or consume actor/global
admission counters.

All spend-related controls still apply. The research worker uses the same daily budget ledger,
reservation amounts, request limits, prompt, Claude tools, complete response retention, validation,
and optional length-repair path as a normal public invocation.

The existing public thread worker fetches the invocation again with `depth=0` and the configured
parent height. It stores the raw snapshot and canonical root-to-invocation ancestor text before
research begins. The existing research worker freezes an exact reply record, and the existing reply
worker authenticates as the configured bot and reconciles the deterministic record key before and
after any write.

Only the manually selected invocation may be nonterminal when worker queues start. Jobs left behind
for older terminal demos are harmless stage-checked no-ops. The runtime never starts while another
invocation could make an external call.

## Idempotency and Resumption

The command treats the invocation URI as its operator-facing idempotency key:

- If no row exists, it creates the receipt and first job.
- If one nonterminal row exists, it attaches to it and repairs only missing or safely recoverable work
  for that same invocation.
- If the row is complete, it reports the stored reply URL without running Claude or writing again.
- If the row is terminally ineligible or failed, it reports the stored category and exits. Retrying a
  failed provider response continues to use the existing explicit `just reprocess` mechanism when
  applicable; `live-run` does not silently reset terminal failures.
- If contradictory rows exist for the same URI, the command fails closed and reports their local IDs.
- If a different invocation is nonterminal, the command fails closed and reports its local ID and
  URL without starting workers.

If the public invocation is edited between runs, existing canonicalization rules determine whether
the current post still directly mentions the bot. The command never creates a second public reply
merely because the CID changed. It attaches by URI and lets thread validation fail if the edited post
is no longer a valid invocation.

`SIGINT` and `SIGTERM` stop the foreground observer and local workers cleanly. An Anthropic request
already sent follows the existing interruption and retained-envelope recovery rules. An ambiguous
ATProto write follows the existing read-before-write reconciliation path. No signal handler marks a
workflow failed solely because the operator stopped the command.

## Secrets and Configuration

The wrapper loads only the secrets this command needs:

- `BOT_APP_PASSWORD`
- `ANTHROPIC_API_KEY`

The existing allowlisted `secrets.sh` mechanism reads them from the item named by
`BITWARDEN_ITEM_ID`. Missing Fly or Phoenix deployment secrets do not block the command.

The command requires valid non-secret bot settings, including `BOT_DID`, `BOT_HANDLE`, and
`BOT_PDS_URL`, plus a positive `ANTHROPIC_DAILY_BUDGET_USD`. `ContextBot.ATProto.Session` already
rejects a session whose authenticated DID differs from `BOT_DID`; the live runner must force
authentication before admitting the invocation so an identity/configuration error cannot incur a
Claude charge.

Logs follow the existing `CONTEXT_BOT_LOG_PATH` behavior. Human progress and the final reply URL go
to stdout. Secrets, JWTs, authorization headers, and app passwords never appear in either stream.

## Operator Experience

At startup, stdout clearly states that this is a live run and identifies the bot DID and invocation
URI before processing. It then reports the durable local invocation ID, whether the run was created,
attached, or already complete, and stage-oriented progress equivalent to the dry-run command.

Successful output includes:

```text
status=complete
reply_url=https://bsky.app/profile/getcontext.bot/post/...
```

Failure output includes the terminal stage and safe failure category, never credentials or complete
provider payloads. Budget deferral is reported as deferred rather than failed. The foreground wait
has a finite configurable timeout, but reaching that timeout leaves the workflow resumable.

## Error Policy

- Invalid URLs, missing mention facets, self-authored invocations, wrong bot configuration, and
  database-path collisions fail before Claude research or ATProto publication.
- Public post resolution and thread-fetch transient failures use bounded retries.
- Anthropic budget exhaustion remains a durable deferral and makes no provider request.
- Provider authentication, response, and validation failures retain the existing categorized state
  and complete response envelopes.
- PDS authentication failure is terminal for publication and does not discard the frozen intent.
- Ambiguous publication is reconciled by reading the deterministic ATProto record before any retry.
- No local error produces a second public error reply.

## Testing Strategy

Implementation follows behavior-first ExUnit and shell tests. Tests use fake public AppView,
Anthropic, session, and PDS boundaries; automated tests never publish to Bluesky.

Coverage must prove:

- the `just live-run` wrapper loads only its required secrets, uses the isolated database, preserves
  arguments exactly, and forwards termination signals;
- invocation URL resolution accepts supported forms and rejects invalid or mismatched posts;
- a direct mention of the configured bot is admitted with `operator_live_demo`, while a missing
  facet, self-post, or wrong target fails before research;
- actor eligibility and admission counters are bypassed, but daily Anthropic budget reservations are
  not;
- receipt insertion and the first job are atomic and repeated commands attach by URI;
- a complete invocation reports its existing reply without new Anthropic or PDS calls;
- an edited CID cannot create a second invocation or public reply;
- a different nonterminal invocation prevents queue startup, while unrelated terminal rows cannot
  make external calls;
- interruption leaves a resumable stage and rerunning completes the same invocation;
- the selected invocation and ancestors, but no descendants, reach Claude;
- the existing deterministic publication path writes exactly one reply and reconciles ambiguous
  results; and
- progress, terminal output, and logs contain no secrets.

A manual smoke test is intentionally separate from the automated suite: publish a direct mention
from another account, run `just live-run <invocation-url>`, observe one reply from `@getcontext.bot`,
then rerun the command and confirm it reports the same reply without another model request or post.

## Acceptance Criteria

The feature is complete when an operator can select one real public direct mention, run the local
command without enabling or deploying the bot, and receive exactly one public reply produced by the
existing ancestor-aware research pipeline. The run is durable across interruption, honors the daily
Anthropic budget, never evaluates ordinary actor eligibility, never polls or processes another
mention, and is idempotent when the same invocation URL is supplied again.
