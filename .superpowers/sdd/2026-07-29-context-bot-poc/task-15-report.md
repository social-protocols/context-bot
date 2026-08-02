# Task 15 report

Status: DONE

## Summary

- Extended the atomic Bitwarden allowlist to `FLY_API_TOKEN`, `SECRET_KEY_BASE`, `BOT_APP_PASSWORD`, and `ANTHROPIC_API_KEY` without printing values or exporting ignored fields.
- Made `just deploy` authenticate through the exported Fly token and stage exactly the other three runtime secrets before deployment.
- Added safe disabled-by-default Fly and local example settings, with empty operator-supplied bot identity placeholders and explicit model, tool, retry, retention, admission, queue, budget, reservation, and pricing bounds.
- Replaced the scaffold README with an operator runbook covering Devbox startup, migrations, safe health/state inspection, secrets, deployment/activation authorization, eligible and ineligible manual tests, and application/data rollback boundaries.
- Updated AGENTS with the implemented POC pipeline and safety invariants while preserving isolated-worktree rules and making live authorization requirements explicit.

## Files

- `secrets.sh`
- `test/secrets_test.sh`
- `justfile`
- `fly.toml`
- `.env.example`
- `README.md`
- `AGENTS.md`
- `.superpowers/sdd/2026-07-29-context-bot-poc/task-15-report.md`

## TDD evidence

- RED: `direnv exec . bash test/secrets_test.sh` exited 1 because the existing two-field loader accepted a payload that deliberately omitted `ANTHROPIC_API_KEY`: `FAIL: partial item unexpectedly succeeded`.
- GREEN: after extending the loader and deploy recipe, the same command exited 0 with `secrets tests passed`.
- The shell test executes the real sourced loader and real `just deploy` recipe against executable `bw`/`fly` boundary fakes. It proves partial cleanup, ignored-field isolation, exact name-only output, Fly-token authentication, exactly three staged application secrets, and stage-before-deploy ordering.

## Scoped audit

- `fly.toml` parses through Nix `builtins.fromTOML`; its committed bot switch is false and DID/handle/PDS values remain empty until supplied by the operator.
- Sourcing `.env.example` and loading it through `ContextBot.Settings` succeeds with the bot disabled, no placeholder identity, and an exact 20,000,000-microdollar daily budget.
- Direct AppView (`https://api.bsky.app`) and poller cadence/page cap (30 seconds/five pages) are fixed POC behavior, so they are documented rather than exposed as ignored environment variables.
- The runbook's SQLite examples select only counts, identifiers, stages, categories, and monetary/storage aggregates. It warns against printing stored post/provider bodies or credentials.
- The runbook distinguishes one public reply from potentially multiple provider continuations, requires external authorization for Fly resource creation/deploy/inspection and live network tests, and does not invent a public bot identity.
- No deployment or Bluesky/Anthropic request was made.

## Verification

- `direnv exec . bash test/secrets_test.sh`: passed, exit 0.
- `direnv exec . just check`: 311 ExUnit tests passed; shell tests, formatting, warnings-as-errors compilation, Credo, ShellCheck, and Dialyzer all passed; exit 0.
- `direnv exec . just docker-build`: built `context-bot:local` successfully, image SHA `73a355085c09868a61c11f30f84d12e6aeacfaf9f6567d19e4a1cffb8c2a0dff`; exit 0.
- Local container smoke: ran as the host UID with `BOT_ENABLED=false` and a `/private/tmp/context-bot-task15-smoke.*` mounted database; `GET /health` returned HTTP 200 with the bot disabled/session disabled, and the container plus temporary directory were removed by trap.
- `git diff --check`: clean.

## Environmental note

The first Docker build attempt could not reach the configured Docker Desktop socket because the daemon was stopped. The configured context and socket were correct; after starting Docker Desktop, the unchanged build passed.

## Concerns

- The real `BOT_DID`, `BOT_HANDLE`, and `BOT_PDS_URL` are intentionally unresolved and required before activation.
