# Agent guide

Guidance for any coding agent (Claude Code, Codex, Cursor, etc.) working in this repository. `CLAUDE.md` points here.

Always-on context: see `knowledge-base/learnings.md` for distilled facts and constraints from prior investigations.

## Deliberati shipping

Canonical copy: `/home/box/deliberati/ops/AGENTS.md`. Cursor cloud agents **only** read `AGENTS.md` in **this** repo. There is no account-wide master. Keep the in-repo file in sync with that ops file.

This file is for humans and Cursor cloud agents working in this repository.

### Merge

Squash the PR to **one commit**, then **fast-forward** onto `main`. That squash commit **is** HEAD of `main`.

- No merge commits
- Rebase-merge is **not** the path (it keeps N commits)
- GitHub’s “Squash and merge” is the button
- **Do not merge** unless Jonathan explicitly says so for that PR (`gh pr merge --squash` is still a merge)
- Never `gh pr merge --merge`. Do not `--rebase` unless he says so for that PR

The squash SHA differs from the PR head. Treat the **code** as identical. Do not write SHA-dependent tests.

### CI and deploy

Test on the PR (the code that becomes `main`). After squash+FF, **deploy immediately**. Do **not** re-run format/compile/test on push to `main` (that is how a post-merge red happens after deploy already shipped). `main` workflows may deploy.

Branch protection must **require** those PR checks so untested code cannot merge.

When CI fails on a PR, notify or resume the Cursor cloud agent that owns that branch. Do not poll. Do not merge to “fix” CI.

### GitHub settings (human, once per repo)

Settings → General → Pull Requests:

- Allow merge commits: **off**
- Allow squash merging: **on**
- Allow rebase merging: **off**

Settings → Branches → rule on `main`:

- Require linear history: **on**
- Require the PR checks (e.g. Test & Quality Check, Type Check) before merge

Bots do not flip admin settings from the Grok computer.

### Cursor cloud agents

Launch with model **Grok 4.6** (`grok-4.6`). Fallback **Claude Sonnet 4.6** (`claude-sonnet-4-6`) if Grok 4.6 is unavailable. Not Opus unless Jonathan says so for that run.

Start new work from current `main` on a new VM. Rebase onto `origin/main` before opening or updating a PR. Reply to the existing cloud agent for the same PR; do not launch a second one on the same branch.

### Git hooks

If this repo has `.githooks`, env install must set `core.hooksPath=.githooks`. Do **not** `git commit` or `git push --no-verify` unless Jonathan says so. CI is the backstop, not the only gate.

### Incomplete work

The Bot that owns this repo owns open PRs, CI, merge conflicts, and drafts. Check at the weekday 8:56 America/Denver run and whenever a signal arrives. Act without waiting to be nudged. Stay silent if nothing is new.

When `main` moves: rebase remaining **non-parked** `cursor/*` PRs. Skip PRs Jonathan has parked (do not nag, do not rebase).

### Do not

- Put tokens, keys, or secrets in this repo, in docs, or in chat
- Merge, spend, publish, or send external mail unless Jonathan says so
- Enable a live bot or production flag unless he says so

## Project scope

Context Bot is an on-demand Bluesky / ATProto context bot. A user directly mentions it in a public thread and asks for context; the POC retrieves the invocation and ancestor chain, requests Claude analysis with server-side research, and publishes one concise Bluesky reply.

The POC is direct-mention-only, not proactive moderation. It has no UI and does not publish audit records, audit pages, or IPFS artifacts. Do not add those deferred MVP features or new business-domain boundaries without an approved design.

## Environment

Devbox plus direnv is the mandatory development environment. Devbox supplies Elixir 1.20, Erlang/OTP 28, SQLite, `just`, Fly, Bitwarden CLI, Docker CLI, and code-quality tools.

- In a human terminal, run `direnv allow` once per checkout or worktree, then use `just ...`.
- In automated or non-interactive shells, always run `direnv exec . <command>` so the Devbox environment is applied.
- Do not assume globally installed Elixir, Erlang, SQLite, Fly, Bitwarden, Docker client, or quality tools.
- A host Docker daemon is required only for local image builds.
- Cursor cloud agents boot from `.cursor/Dockerfile` (hexpm Elixir/OTP, not Nix). Keep that image aligned with the non-Beam packages in `devbox.json`. Do not replace the Devbox+direnv human workflow.

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

After completing each user prompt, commit the changes with a concise message explaining what changed. Merge-to-`main` and rebase-before-PR rules are in **Deliberati shipping**.

### Git hooks

The repository uses local git hooks in `.githooks/` to catch issues before CI:

- **pre-commit**: runs `mix format` on staged Elixir files and compiles with warnings-as-errors
- **pre-push**: runs the full test suite (`mix test` plus shell script tests)

Cursor cloud agents set `core.hooksPath=.githooks` during environment setup. The hooks run on every commit and push. Bypass policy is in **Deliberati shipping**.

### GitHub Actions

`Test & Quality Check` and `Type Check` run on pull requests targeting `main` (and on manual `workflow_dispatch`), not on push to `main`. After squash+fast-forward onto `main`, only Deploy runs.

## Cursor Cloud specific instructions

Before starting any work, `git fetch origin` and update to current `origin/main` (rebase the task branch onto `origin/main` if already on a feature branch). Do not assume the VM checkout or Cursor Build snapshot is current. Fetch and rebase again before opening or updating a PR if `main` has moved.

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

Run `direnv exec . just check` before any completion claim. For release or deployment changes, also run `direnv exec . just docker-build` and smoke-test `/health`.

## Architecture

This is one Phoenix API application, not an umbrella. `ContextBot.Application` starts Repo and Finch always, and starts Oban, `ContextBot.ATProto.Session`, and `ContextBot.Mentions.Poller` only when the validated settings enable the bot. `GET /health` returns bounded operational aggregates and never stored content or credentials. Public `GET /invocations` is a GET-only HTML log of operational metadata (counts, spend, tokens, status, actor handle, Bluesky and Standard.site links, short error reasons). It does not show post bodies, prompts, envelopes, or secrets, and it has no reprocess or other mutation endpoints. Reprocess stays on `just fly-reprocess` over Fly SSH.

The public pipeline is `Mentions.Poller` → `EligibilityWorker` → `ThreadWorker` → `ResearchWorker` → `ReplyWorker`; `DeferredWorker` repairs missing jobs and reconsiders bounded deferred work. The read-only local path is `just dry-run` → `ThreadWorker` → `ResearchWorker` for a selected public post, or `just dry-run` → `ResearchWorker` for a question-only local subject; both terminate at `complete` without reply construction. The explicit local public-write path is `just live-run` → `ThreadWorker` → `ResearchWorker` → `ReplyWorker`; it uses `data/live-demo.db` by default, starts no poller, bypasses only actor eligibility, and processes one selected direct mention. `Workflow.Store` and Ecto/SQLite own invocation checkpoints, leases, budget entries, exact bounded provider response envelopes, and any public frozen reply intent. Development and test databases live under ignored `data/`; Fly mounts `/data/context_bot.db`.

External request behavior is one validated startup snapshot. Keep `APPVIEW_URL` pinned to the reviewed public AppView origin; keep the bounded poll interval/page cap, ATProto HTTP/session timeouts, thread-fetch timeout, Anthropic HTTP timeout/API version, and Anthropic server-tool versions runtime configurable through `ContextBot.Settings`. Malformed or out-of-range values must fail startup. The release image includes the SQLite CLI solely for explicitly authorized, read-only, aggregate Fly inspection with a busy timeout.

Preserve these POC invariants:

- ingest only exact direct mentions and never call notification `updateSeen`;
- fetch only the invocation plus ancestors (`depth=0`), never descendants;
- admit every exact direct mention and classify the actor into a rate-limit tier: operator allowlist (skip actor hourly/daily windows), confirmed Skywatch `bluesky-elder` or bidirectionally verified `bsky.team` (`ACTOR_DAILY_LIMIT`, default 5), or public (`ACTOR_DAILY_LIMIT_PUBLIC`, default 1); a labeler or identity outage degrades to public instead of rejecting; `ACTOR_HOURLY_LIMIT` remains a burst cap for non-operator actors; global hourly/daily and `max_pending` still apply to everyone;
- reserve integer-microdollar budget before Anthropic work and mark attempts sent before a request can escape;
- preserve complete provider responses within the configured per-response and cumulative storage bounds;
- treat `dry_run = true` as permanently non-publishable: use only unauthenticated public AppView reads, skip eligibility/mention rates, retain all Anthropic spending and safety limits, and never create a reply intent or publication claim;
- treat `eligibility_method = "operator_live_demo"` as authorization for only the explicitly selected public invocation: keep `dry_run = false`, retain spending and publication safeguards, use an isolated database, and never start polling;
- freeze one repository/rkey/record reply intent, fence research and publication with leases, and reconcile ambiguous PDS writes rather than allocating a second reply;
- send `web_search`/`web_fetch` with `allowed_callers: ["direct"]` and do not declare a `code_execution` tool; treat a failed `code_execution` or `bash_code_execution` result (non-zero `return_code`, documented tool-result error, or timeout) as a terminal `provider_response`; do not compact, split, or publish;
- keep `web_fetch` `citations.enabled=false` because structured JSON plus native citations 400s; require `full_response` to include markdown `[label](https://...)` URLs for every web source actually used, and do not invent URLs; `compact_reply` stays plain text;
- treat in-band `max_uses_exceeded` web-tool errors as a completed search/fetch turn and still select compact/`full_response` from that envelope;
- on SIGTERM, stop poller/admission work and let in-flight research and reply finish within Fly's 300s kill_timeout; a sent Anthropic attempt without an envelope waits out `ANTHROPIC_HTTP_TIMEOUT_MS` then starts a new budget attempt rather than remaining `interrupted_after_send` forever;
- when structured `disposition=reply` has a blank `title` after trim but nonempty `compact_reply` and `full_response`, rewrite the title with a cheap `ANTHROPIC_TITLE_MODEL_ID` (default Haiku) call that reuses the leftover `:repair` reservation and `ANTHROPIC_LENGTH_REPAIR_MAX_TOKENS`; do not rewrite `compact_reply`; over-long compact still pack-first splits with `repair_used` false; leftover `invalid_structured_output` rows stay failed until operator reprocess;
- recover durable work oldest-first with bounded scans; automatic `recover_failed` reopens interruptions and locally retryable envelopes, not deterministic parser hard-fails (`code_execution_failed`, `invalid_structured_output`, `unexpected_tool_use`, and other parser reasons that will not change on replay); operator reprocess of `code_execution_failed` starts a new paid attempt;
- keep failures finite and credential-free.

## Testing guidance

Write behavior-first ExUnit tests for application features and shell tests for secret-loading behavior. For every feature or bug fix, watch the new test fail for the intended reason before implementing, then watch it pass. Run compilation with warnings as errors. Completion claims require fresh command output, not confidence or an earlier run.

## Secrets and deployment

Never commit credentials, `.env` files, Bitwarden payloads, or secret values in logs. `secrets.sh` accepts only `FLY_API_TOKEN`, `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` custom-field names from the item named by `BITWARDEN_ITEM_ID`, and exports only explicitly requested names. `just dry-run` requests only the Anthropic key; `just live-run` requests only the bot app password and Anthropic key. `just deploy` uses `FLY_API_TOKEN` for authentication and stages exactly the other three runtime secrets before deploying.

Committed Fly configuration must remain `BOT_ENABLED=false` until the operator supplies and reviews the real public bot DID, handle, and PDS. Any live deploy, Fly inspection, Bluesky/Anthropic smoke test, public reply, or other external-effect operation always requires explicit user authorization; prior authorization for local implementation or verification does not count. A paid dry run additionally requires a post supplied by the operator in that request. Never invent a live test target or run one as part of ordinary verification.
