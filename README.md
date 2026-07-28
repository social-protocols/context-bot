# Context Bot

An experimental, on-demand Bluesky / ATProto context bot. For the MVP it acts only when directly mentioned in a public thread; it is not a proactive moderation system.

## Status

Repository scaffold only. ATProto ingestion, Claude analysis, audit records, and replies are not implemented yet. Elixir is an intentional experiment and the implementation language may change if the project teaches us to prefer another stack.

## Prerequisites

- Devbox
- direnv, hooked into your shell
- Docker daemon for `just docker-build`
- Fly and Bitwarden accounts only for deployment

Devbox supplies Elixir, Erlang, SQLite, `just`, Fly, Bitwarden CLI, Docker CLI, and the remaining project tools.

## Quick start

```bash
direnv allow
just setup
just check
just dev
```

The service listens on `http://localhost:4000`; `GET /health` returns `{"status":"ok"}`.

## Commands

| Command | Purpose |
|---|---|
| `just` / `just help` | List recipes. |
| `just setup` | Install Hex/Rebar and locked Mix dependencies, then prepare SQLite. |
| `just dev` | Prepare dependencies/database and start Phoenix. |
| `just test [path]` | Run all tests or one ExUnit test path. |
| `just format` | Format Elixir and shell files. |
| `just format-check` | Check formatting without changing files. |
| `just lint` | Run Credo and ShellCheck. |
| `just typecheck` | Run Dialyzer. |
| `just check` | Run the complete local quality gate. |
| `just db-create` / `db-migrate` / `db-reset` | Manage the local SQLite database. |
| `just docker-build` | Build `context-bot:local`. |
| `just secrets` | Load and validate approved Bitwarden fields without printing values. |
| `just deploy` | Stage application secrets and deploy to Fly. |
| `just fly-status` / `fly-logs` | Inspect the Fly application. |

## Persistence

Development uses the ignored `data/context_bot_dev.db`; tests create partition-aware files under `data/`; Fly uses `/data/context_bot.db` on `context_bot_data`.

The approved MVP design stores exact intended ATProto records and blobs in SQLite with their locally calculated CIDs, then asynchronously converges that state to the bot's PDS. Setting `SYNC_TO_ATPROTO=false` will retain the complete intended graph without publishing records/blobs or mutating profile, reply, or notification-seen state. This behavior is designed but not implemented yet; see [`docs/superpowers/specs/2026-07-27-context-bot-mvp-design.md`](docs/superpowers/specs/2026-07-27-context-bot-mvp-design.md).

## Deployment

Create the Fly app and one volume before the first deploy:

```bash
fly apps create context-bot-jwarden
fly volumes create context_bot_data --region den --size 1 --snapshot-retention 14
```

Create a Bitwarden item with custom fields `FLY_API_TOKEN` and `SECRET_KEY_BASE`. Export that item's UUID as `BITWARDEN_ITEM_ID`, then run:

```bash
just secrets
just deploy
```

The MVP intentionally runs one Machine with one local volume. That accepts downtime and possible data loss between snapshots; it is not a replicated production database design.

## Isolated worktrees

Create substantial feature work under the ignored `.worktrees/` directory:

```bash
git worktree add .worktrees/my-feature -b feature/my-feature main
cd .worktrees/my-feature
direnv allow
just setup
```

Each worktree keeps its own `deps/`, `_build/`, and `data/` state.
