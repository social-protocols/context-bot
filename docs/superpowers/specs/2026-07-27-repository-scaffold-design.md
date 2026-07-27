# Context Bot Repository Scaffold Design

**Date:** 2026-07-27

## Goal

Create a reproducible, deployment-ready foundation for an on-demand Bluesky / ATProto context bot in Elixir. A new developer with Devbox and direnv installed should be able to clone the repository, authorize direnv, and immediately use the documented `just` commands.

This scaffold establishes the development and deployment environment only. It does not implement mention ingestion, thread retrieval, Claude analysis, audit publication, or Bluesky replies.

## Decisions

- Build one Phoenix API-only application named `context_bot`, with Elixir module namespace `ContextBot`.
- Use Phoenix 1.8 on the current stable release line and Elixir 1.20 on Erlang/OTP 28. Devbox records the resolved system packages in `devbox.lock`; Mix records Elixir dependencies in `mix.lock`.
- Generate no HTML, LiveView, frontend assets, dashboard, or mailer.
- Do not create speculative business-domain modules. Domain boundaries will be designed with the first bot feature.
- Include Ecto with SQLite. SQLite is operational storage for local state and a future durable outbox/cache; it is not the intended canonical audit trail.
- Treat successfully published ATProto records as the eventual source of truth for audits.
- Deploy the MVP as one Fly Machine with one mounted volume. This accepts temporary downtime and the loss window inherent in a single local volume while the bot is experimental.
- Declare Bitwarden CLI as `bitwarden-cli@latest` in `devbox.json`, rather than pinning its requested package version. The generated Devbox lock still records the concrete resolution used by a checkout until dependencies are deliberately refreshed.

## Application Shape

The repository contains a conventional, single Phoenix application rather than an umbrella:

- `ContextBot.Application` owns the OTP supervision tree.
- `ContextBot.Repo` owns Ecto access to SQLite.
- `ContextBotWeb.Endpoint` and `ContextBotWeb.Router` expose the HTTP API.
- `GET /health` returns a small JSON success response and is the Fly health-check target.
- `priv/repo/migrations/` exists for future schema changes, but the scaffold creates no bot-specific tables.

The SQLite path is environment-aware:

- Development uses `data/context_bot_dev.db`.
- Tests use an isolated test database beneath `data/`, including `MIX_TEST_PARTITION` when present.
- Production requires `DATABASE_PATH`, configured as `/data/context_bot.db` in `fly.toml`.

The entire `data/` directory is ignored by Git.

## Reproducible Development Environment

`devbox.json` supplies the project tools:

- Elixir 1.20 and Erlang/OTP 28
- SQLite
- `just`
- `flyctl`
- `bitwarden-cli@latest`
- Git, `jq`, `curl`, and `shellcheck`

The Devbox shell installs Hex and Rebar non-interactively and fetches the dependencies from `mix.lock`. These operations are idempotent, so entering an existing environment is fast.

`.envrc` uses Devbox's generated direnv integration. A human runs `direnv allow` once in each checkout or worktree. Automated or non-interactive shells run project commands as:

```bash
direnv exec . just check
```

No development command should depend on globally installed Elixir, Erlang, SQLite, Fly, or Bitwarden tools.

## Command Interface

The root `justfile` is the public command interface:

| Command | Purpose |
|---|---|
| `just` / `just help` | List available recipes. |
| `just setup` | Install Hex/Rebar and locked Mix dependencies, then prepare the development database. |
| `just dev` | Start the Phoenix server. |
| `just test [path]` | Run all ExUnit tests or one supplied test path. |
| `just format` | Format Elixir and repository shell files where applicable. |
| `just format-check` | Check Elixir formatting without changing files. |
| `just lint` | Run Credo in strict mode and ShellCheck. |
| `just typecheck` | Build the Dialyzer PLT and run Dialyzer. |
| `just check` | Run format checking, compilation with warnings-as-errors, linting, tests, and type checking. |
| `just db-create` | Create the configured SQLite database. |
| `just db-migrate` | Run Ecto migrations. |
| `just db-reset` | Drop, recreate, and migrate the local database. |
| `just docker-build` | Build the production Docker image locally. |
| `just secrets` | Load and validate the approved Bitwarden-backed deployment secrets in a subprocess for diagnosis without printing values. |
| `just deploy` | Load secrets, stage Fly runtime secrets, and deploy. |
| `just fly-status` | Show Fly application status. |
| `just fly-logs` | Stream Fly application logs. |

Recipes use Bash with `set -euo pipefail`. Recipes that need environment variables source `secrets.sh` and run their dependent commands in the same shell process.

## Secrets

`secrets.sh` is safe to source and is committed without secret values. It:

1. Requires `BITWARDEN_ITEM_ID` to identify the Bitwarden item.
2. Calls `bw get item` and reads named custom fields from the returned JSON.
3. Exports only the scaffold's explicit allowlist: `FLY_API_TOKEN` and `SECRET_KEY_BASE`.
4. Fails if Bitwarden is locked, the item cannot be fetched, or an allowlisted value is missing.
5. Logs secret names only, never their values.

Future features add their required keys to the allowlist deliberately. Local development can provide configuration through the calling shell; no committed `.env` file contains credentials.

`just deploy` stages `SECRET_KEY_BASE` with `fly secrets set --stage`, then runs `fly deploy`. `FLY_API_TOKEN` authenticates `flyctl` but is not uploaded as an application runtime secret.

## Fly Deployment

The deployment uses a conventional multi-stage Docker build:

1. A Hex Elixir/Erlang Debian image installs build dependencies and creates an OTP release.
2. A minimal Debian runtime image contains the release and SQLite runtime libraries.
3. The release runs as an unprivileged user.
4. A release command runs Ecto migrations before the application update.

`fly.toml` defines:

- App name `context-bot-jwarden`.
- Primary region `den`.
- Internal HTTP port `4000`, exposed on ports 80 and 443 with HTTPS enforced.
- `PHX_SERVER=true` and `DATABASE_PATH=/data/context_bot.db` in runtime configuration.
- A volume named `context_bot_data` mounted at `/data`, with 14-day snapshot retention.
- A `GET /health` service check.
- One shared-CPU, 1 GB Machine for the MVP.

The README makes the single-volume tradeoff explicit: Fly volumes are local to one host and do not provide built-in replication. ATProto publication is the long-term durability boundary; SQLite only protects work that has not completed that publication flow.

## Tests and Verification

The scaffold includes:

- A router test proving `GET /health` returns HTTP 200 and the expected JSON body.
- The Phoenix-generated application and data-case test helpers needed for later work.
- Credo as a development/test dependency.
- Dialyxir as a development/test dependency.
- ShellCheck coverage for `secrets.sh`.
- Docker image construction as the production-build verification.

Before the scaffold is considered complete, verification runs inside direnv/Devbox and demonstrates:

1. The expected Elixir, Erlang, `just`, Fly, SQLite, and Bitwarden commands resolve from Devbox.
2. `just check` exits successfully.
3. The application boots, migrates its SQLite database, and serves `/health`.
4. `just docker-build` produces the release image.
5. `secrets.sh` fails cleanly without `BITWARDEN_ITEM_ID` and does not print secret values.

An actual Fly deployment is not part of scaffold verification because it changes external infrastructure and requires the final app name, region, Bitwarden item, and Fly account authorization.

## Agent Guidance and Isolated Worktrees

`AGENTS.md` is adapted from the Malasaña Method repository. It keeps the useful environment and Git discipline while removing Python, book-generation, and UI guidance. It documents:

- The project goal and the MVP's direct-mention-only constraint.
- Devbox/direnv as the mandatory execution environment.
- `direnv exec .` for automated commands.
- The canonical `just` commands and verification expectations.
- The current architecture and the rule against inventing domain boundaries prematurely.
- SQLite's non-canonical role.
- Secret-handling rules.
- A linear Git history with concise commits and no merge commits.

For isolated work:

- Create feature worktrees under the ignored `.worktrees/` directory.
- Create them from the repository's main branch with a dedicated feature branch.
- Run `direnv allow` once inside every new worktree.
- Keep `deps/`, `_build/`, and `data/` worktree-local so concurrent work does not share build artifacts or SQLite files.
- Run all verification from inside the feature worktree before committing.
- Do not merge worktree branches implicitly; preserve a linear history with an explicit rebase, fast-forward, or selected cherry-picks.
- Never remove another developer's worktree or discard its changes.

`CLAUDE.md` remains a three-line pointer to `AGENTS.md`, ensuring Claude Code loads the same canonical instructions as other coding agents.

## Documentation

The root README explains:

- The on-demand context-bot goal and explicit non-goals.
- Prerequisites: Devbox and direnv, with Docker required only for local image builds.
- First checkout and first worktree setup.
- The common `just` commands.
- Local SQLite and Fly-volume behavior.
- Bitwarden/Fly deployment prerequisites without including credentials.
- The project is intentionally experimenting with Elixir and may change implementation language later.

## Excluded From This Scaffold

- ATProto authentication, firehose/Jetstream consumption, thread fetching, record schemas, or record publication
- Claude API clients, tool definitions, prompts, web search/fetch orchestration, or transcript schemas
- Background-job technology or retry policies beyond the future SQLite outbox intent
- Audit-page UI or any other frontend
- Bot-specific database tables
- CI/CD workflows or automatic external deployments
- Multi-Machine SQLite replication, LiteFS, PostgreSQL, or other production data systems
- Final domain/context boundaries

These decisions belong to later vertical-slice designs informed by the actual ATProto and Claude integration requirements.
