# Agent guide

Guidance for any coding agent (Claude Code, Codex, Cursor, etc.) working in this repository. `CLAUDE.md` points here.

## Project scope

Context Bot is an on-demand Bluesky / ATProto context bot. A user directly mentions it in a public thread and asks for context; the eventual bot retrieves the thread, requests Claude analysis with server-side research, publishes an ATProto audit trail, and replies concisely.

The repository currently contains foundation scaffolding only. The MVP is direct-mention-only, not proactive moderation. It has no UI. Do not invent business-domain boundaries, schemas, workers, or integrations before the corresponding feature design is approved.

## Environment

Devbox plus direnv is the mandatory development environment. Devbox supplies Elixir 1.20, Erlang/OTP 28, SQLite, `just`, Fly, Bitwarden CLI, Docker CLI, and code-quality tools.

- In a human terminal, run `direnv allow` once per checkout or worktree, then use `just ...`.
- In automated or non-interactive shells, always run `direnv exec . <command>` so the Devbox environment is applied.
- Do not assume globally installed Elixir, Erlang, SQLite, Fly, Bitwarden, Docker client, or quality tools.
- A host Docker daemon is required only for local image builds.

## Isolated worktrees

Use an isolated worktree for substantial feature or implementation-plan work:

```bash
git worktree add .worktrees/my-feature -b feature/my-feature main
cd .worktrees/my-feature
direnv allow
just setup
```

`.worktrees/` is ignored. Each worktree keeps independent `deps/`, `_build/`, and `data/` directories, so builds and SQLite databases cannot collide. Verify and commit from inside the feature worktree. Never delete another developer's worktree, discard its changes, or integrate its branch without explicit direction.

## Git workflow

After completing each user prompt, commit the changes with a concise message explaining what changed. Do not create merge commits. Keep history linear with an explicit rebase, fast-forward, or selected cherry-picks, and integrate only the commits the user requests.

## Commands

| Command | Purpose |
|---|---|
| `just setup` | Install locked dependencies and prepare SQLite. |
| `just dev` | Start Phoenix on port 4000. |
| `just test [path]` | Run all tests or one ExUnit path. |
| `just format` / `format-check` | Write or verify formatting. |
| `just lint` | Run Credo and ShellCheck. |
| `just typecheck` | Run Dialyzer. |
| `just check` | Run the complete verification gate. |
| `just db-create` / `db-migrate` / `db-reset` | Manage SQLite. |
| `just docker-build` | Build the production image locally. |
| `just secrets` / `deploy` | Validate Bitwarden fields or deploy to Fly. |
| `just fly-status` / `fly-logs` | Inspect the Fly app. |

Run `direnv exec . just check` before any completion claim. For release or deployment changes, also run `direnv exec . just docker-build` and smoke-test `/health`.

## Architecture

This is one Phoenix API application, not an umbrella. `ContextBot.Application` owns the standard OTP tree; `ContextBot.Repo` uses Ecto/SQLite; `ContextBotWeb.Endpoint` exposes the API; `GET /health` is the only initial route.

Development and test databases live under ignored `data/`; Fly mounts `/data/context_bot.db`. SQLite is operational outbox/cache state, not the intended canonical ATProto audit store. No bot-specific domain modules or database tables exist yet.

## Testing guidance

Write behavior-first ExUnit tests for application features and shell tests for secret-loading behavior. For every feature or bug fix, watch the new test fail for the intended reason before implementing, then watch it pass. Run compilation with warnings as errors. Completion claims require fresh command output, not confidence or an earlier run.

## Secrets and deployment

Never commit credentials, `.env` files, Bitwarden payloads, or secret values in logs. `secrets.sh` reads only allowlisted custom fields from the item named by `BITWARDEN_ITEM_ID`; the initial allowlist is `FLY_API_TOKEN` and `SECRET_KEY_BASE`. `just deploy` stages `SECRET_KEY_BASE`, authenticates Fly with `FLY_API_TOKEN`, and deploys. Do not run it without explicit authorization for an external deployment.
