# Context Bot

An experimental, on-demand Bluesky / ATProto context bot. The proof of concept acts only when directly mentioned in a public thread; it is not a proactive moderation system.

The POC durably receives mentions, checks a narrow eligibility policy, captures the invocation and ancestor chain, sends bounded images to Claude for a concise researched answer, and publishes exactly one correctly rooted Bluesky reply. Video-containing threads fail closed with a deterministic capability reply instead of a text-only model answer. SQLite holds workflow, budget, provider-response, and frozen reply state. Audit-record publication, audit pages, IPFS, descendants, and a UI are intentionally out of scope.

## Prerequisites

- Devbox
- direnv, hooked into your shell
- Docker Desktop or another Docker daemon for image builds
- Fly and Bitwarden accounts only for an explicitly authorized deployment

Devbox supplies Elixir, Erlang, SQLite, `just`, Fly, Bitwarden CLI, Docker CLI, and the remaining project tools. Do not substitute globally installed tools.

## Safe local startup

Enter the repository and allow direnv once per checkout or worktree:

```bash
direnv allow
cp .env.example .env
set -a
source .env
set +a
just setup
just db-migrate
just dev
```

The example keeps `BOT_ENABLED=false`, so local startup does not contact Bluesky or Anthropic. `just dev` also runs setup and migrations; the explicit migration command above makes the operator step visible.

In another terminal, inspect the credential-free aggregate health response:

```bash
curl --fail --silent --show-error http://127.0.0.1:4000/health | jq
```

Do not paste logs containing post bodies, provider bodies, Bitwarden payloads, app passwords, or API keys into tickets or chat.

## Local read-only context check

With `BOT_ENABLED=false`, an operator can run the real durable thread and research workflow without a bot account and without posting anything to Bluesky:

```bash
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just dry-run "https://bsky.app/profile/alice.example/post/3abc" "What's missing?"
```

The post may also be a canonical `at://.../app.bsky.feed.post/...` URI. The command loads only `ANTHROPIC_API_KEY` from the Bitwarden item, resolves and fetches the post from the configured public AppView without authentication, stores the selected post plus ancestors and local question in SQLite, runs the normal budgeted Claude research worker, and prints a concise result and integer usage/cost summary. Bluesky access is read-only; Anthropic access is paid. `ANTHROPIC_DAILY_BUDGET_USD` must be present and nonzero.

Context Bot sends at most four image or gallery items across the captured ancestor chain to Claude,
ordered root-to-target and represented by validated `https://cdn.bsky.app` URL blocks. If any captured post
contains video, it skips Anthropic and answers: “I can't analyze videos yet, so I can't reliably
answer a question that may depend on this clip.” A chain with more than four images receives a
similar local capability answer instead of partial research. These paths report zero provider usage
and cost; dry runs still never publish. Malformed or untrusted image metadata fails without an
answer. The command currently requires the configured Anthropic key and daily budget at startup even
when the fetched thread ultimately takes a provider-free capability path.

Human progress is written to stdout. Application logs are structured JSON Lines on stderr by
default; set `CONTEXT_BOT_LOG_PATH` to an absolute path to append those logs to a file instead. Log
metadata is strictly allowlisted and never includes post text, prompts, responses, headers, or
credentials. The ordinary research defaults use medium effort, at most 4,096 output tokens, two web
searches, two web fetches, 10,000 fetched-content tokens, and one tool continuation. Server-side tool
content can still contribute substantially to Anthropic input billing even when it is excluded from
the returned response, so the printed settled cost—not visible response length—is authoritative.

A research HTTP call may take up to five minutes, and the foreground command waits up to fifteen
minutes for the durable workflow. Ctrl-C and SIGTERM clear progress, pause new dry-run dispatch, and
give executing work its configured shutdown grace period. The printed `dry_run_id` remains the
recovery handle. On the next startup, deterministic work resumes automatically. An Anthropic attempt
that was sent but has no committed response envelope is never replayed: its budget becomes
indeterminate and the invocation fails with `interrupted_after_send`, because replay could double
spend while the first request may already have been billed.

If a complete provider response was retained but a local decoder or validator bug incorrectly
marked the invocation failed, an operator can explicitly reopen it without repeating paid research:

```bash
just reprocess 42
```

The command fails closed unless invocation 42 is a provider-response failure with a complete,
successful retained envelope and no ambiguous provider attempt. Run it only with
`BOT_ENABLED=false` and no Context Bot runtime already active against the same SQLite database. The
command starts only the database dependencies, returns the invocation to durable pending work, and
does not start Oban, the mention poller, an ATProto session, or the full application. It therefore
does not contact Anthropic or Bluesky. Start the normal runtime afterward, or rerun the matching
`just dry-run` command, to process the stored envelope. For a public invocation, disable the bot or
put it into maintenance before reprocessing, then restart it afterward. If the stored answer is over
the Bluesky limit, the normal budgeted length-repair call may still occur.

Every row created this way has `dry_run = 1`. It skips mention eligibility and mention-rate admission, but retains provider budgets, response/tool/token/storage limits, retries, leases, and full bounded provider response envelopes. It never starts the notification poller or ATProto session, never creates a reply record, and cannot acquire a publication lease. A budget deferral remains durable for later operator inspection; rerunning the command creates a new check.

Inspect dry-run metadata without selecting stored thread, prompt, response, or answer content:

```bash
sqlite3 -readonly -header -column data/context_bot_dev.db \
  "SELECT id, target_uri, stage, failure_category, received_at, completed_at FROM invocations WHERE dry_run = 1 ORDER BY id DESC LIMIT 20;"
```

Running a real check requires an operator-supplied public post and explicit authorization because it makes external Bluesky reads and a paid Anthropic request.

## Local live public reply

`live-run` is an explicit public-write demo for one existing direct mention. Configure `BOT_DID`,
`BOT_HANDLE`, `BOT_PDS_URL`, and a positive `ANTHROPIC_DAILY_BUDGET_USD` in `.env`; add
`BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY` as custom fields on the selected Bitwarden item. Then run:

```bash
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just live-run 'https://bsky.app/profile/actor.example/post/3abc'
```

The URL must identify the invocation post containing the question and a direct mention of the
configured bot. This command **publishes a real reply** as the configured `BOT_DID`/`BOT_HANDLE`.
Running it is the operator authorization that bypasses actor eligibility; all Anthropic reservation,
daily-budget, response, validation, and publication safeguards remain active.

The same media rules apply to a live run. A supported image enters the bounded Claude request. A
video or excessive image count bypasses Claude but still freezes and publishes exactly one
deterministic reply through the normal reconciliation-safe reply worker.

The command forces `BOT_ENABLED=false`, starts no notification poller, and processes only the
selected invocation on serial `thread`, `research`, and `reply` queues. Durable state defaults to the
isolated `data/live-demo.db`; `CONTEXT_BOT_LIVE_DATABASE_PATH` can select another dedicated path but
the command rejects development, test, and configured production databases. Ctrl-C stops local
workers without marking the invocation failed. Rerun the same URL to resume or attach; once complete,
it reports the existing reply URL without another Claude request or Bluesky post.

## Commands

| Command | Purpose |
|---|---|
| `just` / `just help` | List recipes. |
| `just setup` | Install Hex/Rebar and locked Mix dependencies, then prepare SQLite. |
| `just dev` | Prepare dependencies/database and start Phoenix. |
| `just test [path]` | Run all tests or one ExUnit test path. |
| `just format` / `format-check` | Write or verify Elixir and shell formatting. |
| `just lint` | Run Credo and ShellCheck. |
| `just typecheck` | Run Dialyzer. |
| `just check` | Run the complete local quality gate. |
| `just db-create` / `db-migrate` / `db-reset` | Manage the local SQLite database. |
| `just dry-run <post> <question>` | Run a durable local-only context check; reads Bluesky and may spend Anthropic budget. |
| `just live-run <invocation-url>` | Process one real direct mention locally and publish its Bluesky reply. Explicit authorization required. |
| `just reprocess <invocation-id>` | With the bot disabled and workers stopped, reopen a guarded provider-processing failure from its retained response; performs no external I/O. |
| `just docker-build` | Build `context-bot:local`. |
| `just secrets` | Validate the allowlisted Bitwarden fields without printing values. |
| `just deploy` | Stage the three runtime secrets and deploy to Fly. External authorization is required. |
| `just fly-status` / `fly-logs` | Inspect the Fly application. External authorization is required. |

## Inspecting local workflow state

These read-only queries show counts and operational aggregates, not stored post or provider content:

```bash
sqlite3 -readonly data/context_bot_dev.db <<'SQL'
.headers on
.mode column
SELECT stage, failure_category, count(*) AS invocations
FROM invocations
GROUP BY stage, failure_category
ORDER BY stage, failure_category;

SELECT queue, state, count(*) AS jobs
FROM oban_jobs
GROUP BY queue, state
ORDER BY queue, state;

SELECT budget_date, state,
       sum(reserved_microdollars) AS reserved_microdollars,
       sum(coalesce(settled_microdollars, 0)) AS settled_microdollars
FROM api_budget_entries
GROUP BY budget_date, state
ORDER BY budget_date DESC, state;

SELECT count(*) AS provider_responses,
       coalesce(sum(storage_bytes), 0) AS stored_bytes
FROM anthropic_response_envelopes;

SELECT (SELECT count(*) FROM invocations) AS invocations,
       (SELECT count(*) FROM api_budget_entries WHERE sent_at IS NOT NULL) AS sent_attempts,
       (SELECT count(*) FROM anthropic_response_envelopes) AS provider_responses,
       (SELECT count(*) FROM invocations WHERE reply_uri IS NOT NULL) AS published_replies;
SQL
```

Development uses the ignored `data/context_bot_dev.db`; tests create partition-aware files under `data/`; Fly uses `/data/context_bot.db` on `context_bot_data`. The Fly deployment is deliberately one Machine with one local volume. It accepts downtime and possible data loss between snapshots; it is not a replicated production database design.

After explicit authorization for a live Fly inspection, use the SQLite CLI included in the release image. `-readonly` prevents writes and the busy timeout allows the query to wait briefly for the application writer without changing data:

```bash
fly ssh console --command \
  "sqlite3 -readonly -cmd 'PRAGMA busy_timeout=5000;' -header -column /data/context_bot.db \
  'SELECT stage, failure_category, count(*) AS invocations FROM invocations GROUP BY stage, failure_category ORDER BY stage, failure_category;'"

fly ssh console --command \
  "sqlite3 -readonly -cmd 'PRAGMA busy_timeout=5000;' -header -column /data/context_bot.db \
  'SELECT (SELECT count(*) FROM invocations) AS invocations, (SELECT count(*) FROM api_budget_entries WHERE sent_at IS NOT NULL) AS sent_attempts, (SELECT count(*) FROM anthropic_response_envelopes) AS provider_responses, (SELECT count(*) FROM invocations WHERE reply_uri IS NOT NULL) AS published_replies;'"
```

Keep live inspection aggregate-only. Do not select raw notifications, threads, Anthropic messages, provider bodies, or frozen reply text.

## Secrets and Fly configuration

Create one Bitwarden item with these four custom fields, using the names exactly:

- `FLY_API_TOKEN`
- `SECRET_KEY_BASE`
- `BOT_APP_PASSWORD`
- `ANTHROPIC_API_KEY`

`secrets.sh` accepts one or more names from that fixed allowlist, disables shell tracing while values are handled, exports only the requested fields after all requested values are present, removes the Bitwarden payload and temporary variables, restores the caller's tracing state, and reports names without values. `just dry-run` requests only `ANTHROPIC_API_KEY`; `just live-run` requests only `BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY`. `just secrets` and `just deploy` request all four; `FLY_API_TOKEN` authenticates Fly, while deploy sends only `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` to `fly secrets import --stage` over standard input. Secret values are never command-line arguments. With `set dotenv-load := true`, `just` reads non-secret local configuration such as `BITWARDEN_ITEM_ID` from the ignored `.env` file automatically.

Before any live deployment, replace the empty `BOT_DID`, `BOT_HANDLE`, and `BOT_PDS_URL` values in `fly.toml` with the real public bot DID, handle, and HTTPS PDS URL. Review the committed limits and the `OPERATOR_ALLOWED_DIDS` comma-separated DID allowlist. Do not set `BOT_ENABLED=true` yet. `APPVIEW_URL` is pinned to the reviewed `https://api.bsky.app` trust root, and authenticated `app.bsky.*` requests explicitly select `did:web:api.bsky.app#bsky_appview` through the PDS service proxy. Polling accepts only a 5,000–3,600,000 ms interval and a 1–20 page cap. ATProto/thread timeouts are capped at 60 seconds, the Anthropic timeout at 10 minutes, parent height at 100, provider output at 64,000 tokens, repair output at 8,192 tokens, each web-tool count at 10, fetched content at 100,000 tokens, continuations at 5, and HTTP retries at 3. Response and aggregate-storage caps are bounded at 16 MB and 128 MB; startup additionally requires enough aggregate storage for every permitted response plus envelope metadata. `QUEUE_CONCURRENCY` must remain exactly `1` so provider execution stays serial. The API version and server-tool types are date-validated. Retain the committed defaults unless a reviewed design or provider change requires otherwise.

Creating the Fly app or volume is also an external effect and requires explicit authorization. Create them once if they do not already exist:

```bash
fly apps create context-bot-jwarden
fly volumes create context_bot_data --region den --size 1 --snapshot-retention 14
```

After explicit authorization for external effects, log in to Bitwarden, unlock the vault, identify the item, validate it, and make the first disabled deployment:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just secrets
just deploy
curl --fail --silent --show-error https://context-bot-jwarden.fly.dev/health | jq
```

The release entrypoint migrates `/data/context_bot.db` before starting Phoenix. Confirm health reports `bot.enabled` as `false`. Activation is a separate, explicit change: set `BOT_ENABLED = "true"` in `fly.toml`, review the identity, limits, budget, and allowlist again, then run `just deploy` only with renewed authorization. Startup fails closed if an enabled deployment lacks identity, budget, or runtime secrets.

## Manual live smoke tests

Live tests call Bluesky and Anthropic and publish a public reply. They always require explicit authorization.

For the eligible test, use either a bidirectionally verified `bsky.team` account, an account with the `bluesky-elder` Skywatch label, or an exact DID listed in `OPERATOR_ALLOWED_DIDS`.

1. With explicit authorization, record the current invocation, sent-budget-entry, provider-response, and completed-reply counts using the aggregate-only `fly ssh console` queries above.
2. Create a public ancestor chain. Mention the bot in a new reply and ask for context.
3. Observe aggregate `/health` and the invocation stage until it becomes `complete` or a categorized terminal failure. Do not print `raw_notification`, `raw_thread`, request messages, or response bodies.
4. Confirm the expected sent provider attempts and exactly one visible bot reply. The reply's parent must be the invocation post. Its root must equal the invocation record's `reply.root` strong reference; for a top-level invocation, the invocation itself is the root. Do not infer the reply root from whichever ancestor happens to be oldest in the captured AppView response.
5. Create a direct reply below the invocation before its poll is processed; confirm that descendant text is absent from the stored canonical thread/provider prompt.
6. Wait through another notification poll and confirm the same invocation still has one reply URI/CID and Bluesky still shows one bot reply.

For the ineligible test, use an account that is not `bsky.team`, has no `bluesky-elder` label, and is absent from `OPERATOR_ALLOWED_DIDS`.

1. Record the sent-budget-entry, provider-response, and completed-reply counts.
2. Mention the bot publicly and wait through a poll and job cycle.
3. Confirm the invocation becomes `ineligible` and every recorded count remains unchanged. There must be no Claude request and no bot reply.

## Rollback

Disable new polling first when incident containment matters: change committed Fly configuration back to `BOT_ENABLED = "false"` and deploy that reviewed configuration with explicit authorization. To restore an earlier application image, list successful releases with their image references and redeploy the selected previous image:

```bash
fly releases --image
fly deploy --image <previous-successful-image-reference>
```

The release startup automatically applies forward migrations. Do not automatically roll SQLite migrations backward: preserve the volume, stop writers, and take or identify a volume snapshot before any database restore or migration rollback. A code rollback and a volume restore are separate operator decisions.

## Isolated worktrees

Create substantial feature work under the ignored `.worktrees/` directory:

```bash
git worktree add .worktrees/my-feature -b feature/my-feature main
cd .worktrees/my-feature
direnv allow
just setup
```

Each worktree keeps its own `deps/`, `_build/`, and `data/` state.
