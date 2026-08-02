# Context Bot

An experimental, on-demand Bluesky / ATProto context bot. The proof of concept acts only when directly mentioned in a public thread; it is not a proactive moderation system.

The POC durably receives mentions, checks a narrow eligibility policy, captures the invocation and ancestor chain, asks Claude for a concise researched answer, and publishes exactly one correctly rooted Bluesky reply. SQLite holds workflow, budget, provider-response, and frozen reply state. Audit-record publication, audit pages, IPFS, descendants, and a UI are intentionally out of scope.

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
| `just docker-build` | Build `context-bot:local`. |
| `just secrets` | Validate the allowlisted Bitwarden fields without printing values. |
| `just deploy` | Stage the three runtime secrets and deploy to Fly. External authorization is required. |
| `just fly-status` / `fly-logs` | Inspect the Fly application. External authorization is required. |

## Inspecting local workflow state

These read-only queries show counts and identifiers, not stored post or provider content:

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

## Secrets and Fly configuration

Create one Bitwarden item with these four custom fields, using the names exactly:

- `FLY_API_TOKEN`
- `SECRET_KEY_BASE`
- `BOT_APP_PASSWORD`
- `ANTHROPIC_API_KEY`

`secrets.sh` reads only those fields, exports them only after every field is present, removes the Bitwarden payload and temporary variables, and reports names without values. `FLY_API_TOKEN` authenticates Fly; `just deploy` stages only `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` as application secrets.

Before any live deployment, replace the empty `BOT_DID`, `BOT_HANDLE`, and `BOT_PDS_URL` values in `fly.toml` with the real public bot DID, handle, and HTTPS PDS URL. Review the committed limits and the `OPERATOR_ALLOWED_DIDS` comma-separated DID allowlist. Do not set `BOT_ENABLED=true` yet. The POC always reads labels and threads directly from `https://api.bsky.app`; it polls every 30 seconds and reads at most five notification pages per poll.

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

1. Record the current invocation, sent-budget-entry, provider-response, and completed-reply counts with the read-only queries above (or equivalent read-only queries against a copy of the Fly SQLite volume).
2. Create a public ancestor chain. Mention the bot in a new reply and ask for context.
3. Observe aggregate `/health` and the invocation stage until it becomes `complete` or a categorized terminal failure. Do not print `raw_notification`, `raw_thread`, request messages, or response bodies.
4. Confirm the expected sent provider attempts and exactly one visible bot reply. The reply's parent must be the invocation post and its root must be the oldest captured ancestor.
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
