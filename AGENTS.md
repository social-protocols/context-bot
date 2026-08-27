# Agent guide

Guidance for any coding agent (Claude Code, Codex, Cursor, etc.) working in this repository. `CLAUDE.md` points here.

Always-on context: see `knowledge-base/learnings.md` for distilled facts and constraints from prior investigations.

## Project scope

Context Bot is an on-demand Bluesky / ATProto context bot. A user directly mentions it in a public thread and asks for context; the POC retrieves the invocation and ancestor chain, requests Claude analysis with server-side research, and publishes one concise Bluesky reply.

The POC is direct-mention-only, not proactive moderation. It has no UI and does not publish audit records, audit pages, or IPFS artifacts. Do not add those deferred MVP features or new business-domain boundaries without an approved design.

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

### Git hooks

The repository uses local git hooks in `.githooks/` to catch issues before CI:

- **pre-commit**: runs `mix format` on staged Elixir files and compiles with warnings-as-errors
- **pre-push**: runs the full test suite (`mix test` plus shell script tests)

Hooks are automatically installed via `git config core.hooksPath .githooks` during the `.cursor/environment.json` install step. Never bypass hooks with `git commit --no-verify` or `git push --no-verify` unless Jonathan explicitly authorizes it for a specific commit. CI is the backstop, not the only gate — hooks provide fast local feedback and reduce CI churn.

## Cursor Cloud specific instructions

Cursor cloud agents automatically install git hooks during environment setup. The hooks will run on every commit and push operation. Do not use `--no-verify` to bypass hooks unless explicitly authorized.

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
| `just dry-run [post] <question>` | Run the durable local-only research path; omit the post for a question-only subject. |
| `just live-run <invocation-url>` | Process one selected direct mention using isolated SQLite and publish its reply. |
| `just docker-build` | Build the production image locally. |
| `just secrets` / `deploy` | Validate Bitwarden fields or deploy to Fly. |
| `just fly-status` / `fly-logs` | Inspect the Fly app. |
| `just fly-dashboard` | Open the 6PN-only `/invocations` dashboard in Google Chrome via `fly proxy` to `context-bot-social-protocols.internal:4001`. |

Run `direnv exec . just check` before any completion claim. For release or deployment changes, also run `direnv exec . just docker-build` and smoke-test `/health`.

## Architecture

This is one Phoenix API application, not an umbrella. `ContextBot.Application` starts Repo and Finch always, and starts Oban, `ContextBot.ATProto.Session`, and `ContextBot.Mentions.Poller` only when the validated settings enable the bot. `GET /health` returns bounded operational aggregates and never stored content or credentials.

The public pipeline is `Mentions.Poller` → `EligibilityWorker` → `ThreadWorker` → `ResearchWorker` → `ReplyWorker`; `DeferredWorker` repairs missing jobs and reconsiders bounded deferred work. The read-only local path is `just dry-run` → `ThreadWorker` → `ResearchWorker` for a selected public post, or `just dry-run` → `ResearchWorker` for a question-only local subject; both terminate at `complete` without reply construction. The explicit local public-write path is `just live-run` → `ThreadWorker` → `ResearchWorker` → `ReplyWorker`; it uses `data/live-demo.db` by default, starts no poller, bypasses only actor eligibility, and processes one selected direct mention. `Workflow.Store` and Ecto/SQLite own invocation checkpoints, leases, budget entries, exact bounded provider response envelopes, and any public frozen reply intent. Development and test databases live under ignored `data/`; Fly mounts `/data/context_bot.db`.

External request behavior is one validated startup snapshot. Keep `APPVIEW_URL` pinned to the reviewed public AppView origin; keep the bounded poll interval/page cap, ATProto HTTP/session timeouts, thread-fetch timeout, Anthropic HTTP timeout/API version, and Anthropic server-tool versions runtime configurable through `ContextBot.Settings`. Malformed or out-of-range values must fail startup. The release image includes the SQLite CLI solely for explicitly authorized, read-only, aggregate Fly inspection with a busy timeout.

Preserve these POC invariants:

- ingest only exact direct mentions and never call notification `updateSeen`;
- fetch only the invocation plus ancestors (`depth=0`), never descendants;
- fail closed unless the actor has a bidirectionally verified `bsky.team` handle, a confirmed Skywatch `bluesky-elder` label, or an exact operator-allowlisted DID;
- reserve integer-microdollar budget before Anthropic work and mark attempts sent before a request can escape;
- preserve complete provider responses within the configured per-response and cumulative storage bounds;
- treat `dry_run = true` as permanently non-publishable: use only unauthenticated public AppView reads, skip eligibility/mention rates, retain all Anthropic spending and safety limits, and never create a reply intent or publication claim;
- treat `eligibility_method = "operator_live_demo"` as authorization for only the explicitly selected public invocation: keep `dry_run = false`, retain spending and publication safeguards, use an isolated database, and never start polling;
- freeze one repository/rkey/record reply intent, fence research and publication with leases, and reconcile ambiguous PDS writes rather than allocating a second reply;
- treat a failed `code_execution` or `bash_code_execution` result (non-zero `return_code`, documented tool-result error, or timeout) as a terminal `provider_response`; do not compact, split, or publish;
- on SIGTERM, stop poller/admission work and let in-flight research and reply finish within Fly's 300s kill_timeout; a sent Anthropic attempt without an envelope waits out `ANTHROPIC_HTTP_TIMEOUT_MS` then starts a new budget attempt rather than remaining `interrupted_after_send` forever;
- keep failures finite and credential-free, and recover durable work oldest-first with bounded scans.

## Testing guidance

Write behavior-first ExUnit tests for application features and shell tests for secret-loading behavior. For every feature or bug fix, watch the new test fail for the intended reason before implementing, then watch it pass. Run compilation with warnings as errors. Completion claims require fresh command output, not confidence or an earlier run.

## Secrets and deployment

Never commit credentials, `.env` files, Bitwarden payloads, or secret values in logs. `secrets.sh` accepts only `FLY_API_TOKEN`, `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` custom-field names from the item named by `BITWARDEN_ITEM_ID`, and exports only explicitly requested names. `just dry-run` requests only the Anthropic key; `just live-run` requests only the bot app password and Anthropic key. `just deploy` uses `FLY_API_TOKEN` for authentication and stages exactly the other three runtime secrets before deploying.

Committed Fly configuration must remain `BOT_ENABLED=false` until the operator supplies and reviews the real public bot DID, handle, and PDS. Any live deploy, Fly inspection, Bluesky/Anthropic smoke test, public reply, or other external-effect operation always requires explicit user authorization; prior authorization for local implementation or verification does not count. A paid dry run additionally requires a post supplied by the operator in that request. Never invent a live test target or run one as part of ordinary verification.
