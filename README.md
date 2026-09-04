# Context Bot

An experimental, on-demand Bluesky / ATProto context bot. The proof of concept acts only when directly mentioned in a public thread; it is not a proactive moderation system.

The POC durably receives mentions, classifies the actor into a rate-limit tier, captures the invocation and ancestor chain, requests Claude analysis with server-side research, and publishes exactly one correctly rooted Bluesky reply. SQLite holds workflow, budget, provider-response, and frozen reply state. The compact Bluesky reply links a Standard.site document that includes the research writeup, the hashed versioned system prompt, the allowlisted Messages API parameters, and the canonical thread that was sent. Custom `org.social-protocols.contextbot.*` audit-record publication, audit pages, IPFS, descendants, and a UI are intentionally out of scope.

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

The application also serves a public homepage at `GET /` and a GET-only invocations log at `GET /invocations`:

```bash
curl --fail --silent --show-error http://127.0.0.1:4000/
curl --fail --silent --show-error http://127.0.0.1:4000/invocations
```

`GET /invocations` shows operational metadata: counts, spend, tokens, status, actor handle, Bluesky links, Standard.site full-response links, and short error reasons. It does not show API keys, post bodies, prompts, or envelopes, and it has no reprocess, reenqueue, recover, or other mutation endpoints. General failed-invocation recovery is `just fly-recover` (the same `Recovery.recover_orphans/1` path as boot). Envelope replay stays on `just fly-reprocess` over Fly SSH. A fresh two-phase research run of the same invocation id stays on `just fly-reenqueue`.

The homepage is reachable via the configured Phoenix host. Serving https://getcontext.bot (the bot's Bluesky handle and site.standard.publication domain) requires separate DNS configuration pointing to the Fly deployment.

Do not paste logs containing post bodies, provider bodies, Bitwarden payloads, app passwords, or API keys into tickets or chat. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

## Local read-only context check

With `BOT_ENABLED=false`, an operator can run the real durable thread and research workflow without a bot account and without posting anything to Bluesky:

```bash
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just dry-run "What's missing?"
just dry-run "https://bsky.app/profile/alice.example/post/3abc" "What's missing?"
```

A single argument is the operator question. That path never fetches a Bluesky thread: it stores the question as a synthetic local subject, runs the normal budgeted Claude research worker, and prints a concise result. The two-argument form still accepts a `bsky.app` post URL or canonical `at://.../app.bsky.feed.post/...` URI, resolves and fetches that post from the configured public AppView without authentication, and stores the selected post plus ancestors and local question in SQLite. A lone `at://` or `bsky.app` post URL is rejected; it still needs a question. Both forms load only `ANTHROPIC_API_KEY` from the Bitwarden item. Bluesky access is read-only; Anthropic access is paid. `BOT_ENABLED` must be `false`, and `ANTHROPIC_DAILY_BUDGET_USD` must be present and nonzero.

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
that was sent but has no committed response envelope is not failed forever: recovery waits until
`sent_at + ANTHROPIC_HTTP_TIMEOUT_MS`, then starts a **new** budget attempt (the original row stays
indeterminate). That can double-charge if Anthropic later completed the first call; a clean SIGTERM
drain should make it rare. Fly `kill_timeout` is 300s (the platform max, equal to the HTTP timeout)
and Oban's shutdown grace period matches it.

If a complete provider response was retained but a local decoder or validator bug incorrectly
marked the invocation failed, an operator can explicitly reopen it without repeating paid research:

```bash
just reprocess 42
```

The command fails closed unless invocation 42 is a provider-response failure with a complete,
successful retained envelope and no in-flight unrecorded attempt still inside the Anthropic HTTP
timeout, or it is `interrupted_after_send` after that timeout (a new attempt is allowed then).
It refuses a row that already has a published `reply_uri` rather than allocating a second Bluesky
TID. Run
it only with `BOT_ENABLED=false` and no Context Bot runtime already active against the same SQLite
database. The
command starts only the database dependencies, returns the invocation to durable pending work, and
does not start Oban, the mention poller, an ATProto session, or the full application. It therefore
does not contact Anthropic or Bluesky. Start the normal runtime afterward, or rerun the matching
`just dry-run` command, to process the stored envelope. For a public invocation, disable the bot or
put it into maintenance before reprocessing, then restart it afterward. If the stored answer is over
the Bluesky limit, the normal budgeted length-repair call may still occur.

For production invocations on Fly, use `just fly-reprocess <id>` instead. This command connects via SSH to the running Fly machine, starts the necessary dependencies, and reprocesses the invocation directly on the production database. It may publish a Bluesky reply and requires explicit operator authorization. The bot remains enabled during reprocessing. Query production invocation status with `just fly-invocation <id>` before reprocessing to inspect failure details and decide whether reprocessing is appropriate.

When the latest retained envelope is a 400 or an obsolete request body (for example a pre-two-phase `json_schema` Messages request), envelope replay is the wrong tool. Reset that same invocation id in place and enqueue a fresh two-phase research run:

```bash
just reenqueue 42
```

`just fly-reenqueue <id>` is the production SSH form. It keeps identity, the thread snapshot, and historical budget/envelope rows, clears the research and publication checkpoint, and inserts one `ResearchWorker` job with `new_attempt: true`. It refuses a published `reply_uri` / part2 / part3, an in-flight provider attempt still inside the Anthropic HTTP timeout, and any row that is not a failed or unpublished-complete invocation with a canonical thread. It does not call `Reprocessor.reprocess/2`.

When a research writeup already exists and only the later structure call failed (for example a 4xx Haiku request), do not reenqueue a second paid research run and do not replay the 4xx envelope. Use the same recovery path boot uses:

```bash
just recover
just recover 22
just fly-recover
just fly-recover 22
```

`just fly-recover` starts the Fly machine if needed, SSHes into the release, and runs `Recovery.recover_orphans/1` or `Recovery.recover_invocation/2`. The no-id scan skips published replies and deterministic parser hard-fails, and resumes a stored writeup with a live `Request.structure/1` when the last provider call is not a replayable 2xx. `just fly-recover <id>` (and `just recover <id>`) passes `operator?: true` so a stored writeup can retry structure after `max_tokens` / `invalid_structured_output` / `empty_compact` / `overlong_compact` / `invalid_repair` without `fly-reenqueue` or another research bill. It may publish a Bluesky reply.

Invocation 30 failed when STRUCTURE_V4 dumped the research writeup into `compact_reply` and both structure and compact-repair hit `max_tokens`. After #129, `just fly-recover 30` stored a live `Request.structure/1` but Runner replayed the latest 2xx `:repair` `max_tokens` envelope and fail-closed without a new POST. After this change is merged and deployed, retry it with `just fly-recover 30` (or `just recover 30` against a local copy of the Fly DB). Recovery still stores the live structure request; Runner now starts a new `:structure` call instead of replaying that hard-fail envelope. Do not `fly-reenqueue` 30. Do not run that recover from this PR.

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

The same media rules apply to a live run. A supported image enters the bounded Claude request. Threads
with more than four images receive a capability answer and bypass research, but video threads proceed
through normal research where Claude answers from public evidence when possible. All replies freeze
and publish through the normal reconciliation-safe reply worker.

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
| `just dry-run [post] <question>` | Run a durable local-only context check; omit the post for a question-only subject. May spend Anthropic budget. |
| `just live-run <invocation-url>` | Process one real direct mention locally and publish its Bluesky reply. Explicit authorization required. |
| `just reprocess <invocation-id>` | With the bot disabled and workers stopped, reopen a guarded provider-processing failure from its retained response; performs no external I/O. |
| `just reenqueue <invocation-id>` | With the bot disabled and workers stopped, reset one failed or unpublished-complete invocation and enqueue a fresh two-phase research run. |
| `just recover [invocation-id]` | With the bot disabled and workers stopped, run the same recovery path as boot; omit the id to scan, or pass one id (`operator?: true` structure-from-writeup retry). May later publish a Bluesky reply. |
| `just fly-reprocess <id>` | Reprocess one production invocation from its retained response on Fly. May publish a Bluesky reply. External authorization required. |
| `just fly-reenqueue <id>` | Reenqueue one production invocation as a fresh two-phase research run on Fly. May publish a Bluesky reply. External authorization required. |
| `just fly-recover [id]` | Recover failed production invocations. With an id, operator structure-from-writeup retry (no second research bill). May publish a Bluesky reply. External authorization required. |
| `just fly-invocation <id>` | Query and display production invocation status by ID on Fly. External authorization required. |
| `just docker-build` | Build `context-bot:local`. |
| `just secrets` | Validate the allowlisted Bitwarden fields without printing values. |
| `just secrets-sync` | Load secrets from Bitwarden and synchronize them to Fly without deploying. External authorization is required. |
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

## Automatic deployment

Quality and tests run on pull requests targeting `main`. After squash+fast-forward onto `main`, a GitHub Actions workflow deploys to Fly; it does not re-run the test suite. To enable automatic deployments, add the `FLY_API_TOKEN` as a GitHub Actions secret:

1. Generate a Fly API token with `fly auth token` or retrieve it from your Bitwarden item.
2. In your GitHub repository, go to Settings → Secrets and variables → Actions.
3. Click "New repository secret" and add:
   - Name: `FLY_API_TOKEN`
   - Secret: Your Fly API token value

The workflow uses the committed `fly.toml` configuration and does not modify `BOT_ENABLED` or other environment variables. Runtime secrets (`SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, `ANTHROPIC_API_KEY`) must be staged separately using `just secrets-sync` or `just deploy` before the first deployment.

## Secrets and Fly configuration

Create one Bitwarden item with these four custom fields, using the names exactly:

- `FLY_API_TOKEN`
- `SECRET_KEY_BASE`
- `BOT_APP_PASSWORD`
- `ANTHROPIC_API_KEY`

`secrets.sh` accepts one or more names from that fixed allowlist, disables shell tracing while values are handled, exports only the requested fields after all requested values are present, removes the Bitwarden payload and temporary variables, restores the caller's tracing state, and reports names without values. `just dry-run` requests only `ANTHROPIC_API_KEY`; `just live-run` requests only `BOT_APP_PASSWORD` and `ANTHROPIC_API_KEY`. `just secrets`, `just secrets-sync`, and `just deploy` request all four; `FLY_API_TOKEN` authenticates Fly, while `secrets-sync` sends only `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` to `fly secrets import` and deploy sends the same three names to `fly secrets import --stage` over standard input. Secret values are never command-line arguments. With `set dotenv-load := true`, `just` reads non-secret local configuration such as `BITWARDEN_ITEM_ID` from the ignored `.env` file automatically.

### Rotating secrets

When secrets in Bitwarden are updated (e.g., after key rotation), synchronize them to Fly without triggering a full deployment:

```bash
just secrets-sync
```

This command loads the current secrets from Bitwarden and updates Fly's secret store. The running application will automatically restart to pick up the new values. Use `just deploy` instead if you also need to deploy code changes.

Before any live deployment, replace the empty `BOT_DID`, `BOT_HANDLE`, and `BOT_PDS_URL` values in `fly.toml` with the real public bot DID, handle, and HTTPS PDS URL. Review the committed limits and the `OPERATOR_ALLOWED_DIDS` comma-separated DID allowlist. Do not set `BOT_ENABLED=true` yet. `APPVIEW_URL` is pinned to the reviewed `https://api.bsky.app` trust root, and authenticated `app.bsky.*` requests explicitly select `did:web:api.bsky.app#bsky_appview` through the PDS service proxy. Polling accepts only a 5,000–3,600,000 ms interval and a 1–20 page cap. ATProto/thread timeouts are capped at 60 seconds, the Anthropic timeout at 10 minutes, parent height at 100, provider output at 64,000 tokens, repair output at 8,192 tokens, each web-tool count at 10, fetched content at 100,000 tokens, continuations at 5, and HTTP retries at 3. Response and aggregate-storage caps are bounded at 16 MB and 128 MB; startup additionally requires enough aggregate storage for every permitted response plus envelope metadata. `QUEUE_CONCURRENCY` must remain exactly `1` so provider execution stays serial. The API version and server-tool types are date-validated. Retain the committed defaults unless a reviewed design or provider change requires otherwise.

Creating the Fly app or volume is also an external effect and requires explicit authorization. Create them once if they do not already exist:

```bash
fly apps create context-bot-social-protocols
fly volumes create context_bot_data --region den --size 1 --snapshot-retention 14
```

After explicit authorization for external effects, log in to Bitwarden, unlock the vault, identify the item, validate it, and make the first disabled deployment:

```bash
bw login
export BW_SESSION="$(bw unlock --raw)"
export BITWARDEN_ITEM_ID="<Bitwarden item UUID>"
just secrets
just deploy
curl --fail --silent --show-error https://context-bot-social-protocols.fly.dev/health | jq
```

The release entrypoint migrates `/data/context_bot.db` before starting Phoenix. Confirm health reports `bot.enabled` as `false`. Activation is a separate, explicit change: set `BOT_ENABLED = "true"` in `fly.toml`, review the identity, limits, budget, and allowlist again, then run `just deploy` only with renewed authorization. Startup fails closed if an enabled deployment lacks identity, budget, or runtime secrets.

## Manual live smoke tests

Live tests call Bluesky and Anthropic and publish a public reply. They always require explicit authorization.

Anyone who directly mentions the bot is eligible. Actor daily limits are tiered: unlimited for `OPERATOR_ALLOWED_DIDS` (actor hourly/daily windows skipped), 5/day for a bidirectionally verified `bsky.team` handle or a confirmed Skywatch `bluesky-elder` label (`ACTOR_DAILY_LIMIT`), and 1/day for everyone else (`ACTOR_DAILY_LIMIT_PUBLIC`). A Skywatch or identity outage degrades the actor to the public tier instead of rejecting the mention. Global hourly/daily limits and `max_pending` still apply to everyone, including the operator. `ACTOR_HOURLY_LIMIT` remains a burst cap for non-operator actors; daily tiers are the actor cap.

1. With explicit authorization, record the current invocation, sent-budget-entry, provider-response, and completed-reply counts using the aggregate-only `fly ssh console` queries above.
2. Create a public ancestor chain. Mention the bot in a new reply and ask for context.
3. Observe aggregate `/health` and the invocation stage until it becomes `complete` or a categorized terminal failure. Do not print `raw_notification`, `raw_thread`, request messages, or response bodies.
4. Confirm the expected sent provider attempts and exactly one visible bot reply. The reply's parent must be the invocation post. Its root must equal the invocation record's `reply.root` strong reference; for a top-level invocation, the invocation itself is the root. Do not infer the reply root from whichever ancestor happens to be oldest in the captured AppView response.
5. Create a direct reply below the invocation before its poll is processed; confirm that descendant text is absent from the stored canonical thread/provider prompt.
6. Wait through another notification poll and confirm the same invocation still has one reply URI/CID and Bluesky still shows one bot reply.

For a public-tier rate-limit check, use an account that is not `bsky.team`, has no `bluesky-elder` label, and is absent from `OPERATOR_ALLOWED_DIDS`, then mention the bot a second time the same day.

1. Record the sent-budget-entry, provider-response, and completed-reply counts after the first public mention has completed.
2. Mention the bot publicly again from the same account and wait through a poll and job cycle.
3. Confirm the second invocation becomes `deferred_rate` until the rolling 24-hour window opens. There must be no additional Claude request and no second bot reply until that window expires.

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
