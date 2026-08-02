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
- Direct AppView, poller bounds, network timeouts, Anthropic API version, and Anthropic server-tool versions are validated runtime settings with conservative documented defaults.
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

## Fix round 1

### Review findings addressed

- Made every failure path in the sourced secret loader complete cleanup under a real caller `set -e`, including removal of partial exports, private values, payloads, and helper functions before returning failure.
- Disabled xtrace before any secret value is handled and restored the caller's prior xtrace state after cleanup. Added a real traced-shell test that rejects values in output.
- Changed deployment staging to `fly secrets import --stage` over standard input. Tests assert exact stdin, no Fly token in the import, no secret value in argv/output, Fly-token authentication, and stage-before-deploy ordering.
- Added and fail-closed validated `APPVIEW_URL`, `POLL_INTERVAL_MS`, `NOTIFICATION_PAGE_CAP`, `ATPROTO_HTTP_TIMEOUT_MS`, `ATPROTO_SESSION_TIMEOUT_MS`, `THREAD_FETCH_TIMEOUT_MS`, `ANTHROPIC_HTTP_TIMEOUT_MS`, `ANTHROPIC_API_VERSION`, `ANTHROPIC_WEB_SEARCH_TOOL_TYPE`, and `ANTHROPIC_WEB_FETCH_TOOL_TYPE`. Wired them through the OTP children and every relevant HTTP/thread/request boundary.
- Corrected the live reply-root check: the published reply must carry the invocation record's `reply.root` strong reference, or the invocation itself when it is top-level; capture order does not define the root.
- Installed the SQLite CLI in the final image and documented explicitly authorized, `-readonly`, aggregate-only Fly inspection with `PRAGMA busy_timeout=5000`.

### TDD evidence

- RED, secret cleanup: the separate Bash process with `set -euo pipefail` exited before its EXIT trap could verify cleanup: `FAIL: errexit exited before secret cleanup completed`.
- RED, deployment transport: the boundary fake rejected the old `fly secrets set` argv flow after being changed to require an exact three-line `fly secrets import --stage` stdin payload.
- GREEN, secrets: `direnv exec . bash test/secrets_test.sh` passed, including real-errexit, xtrace restoration/non-disclosure, exact stdin, argv/output non-disclosure, and ordering checks.
- RED, runtime settings: the focused 97-test suite reported 10 intended failures covering missing startup fields/defaults/validation and still-hardcoded Application, Session, ReqClient, ThreadWorker, AnthropicClient, Request, and Runner behavior.
- GREEN, runtime settings: the same focused suite passed all 97 tests after wiring the validated settings.

### Fresh verification

- `direnv exec . just check`: 317 ExUnit tests passed; secret shell tests, formatting, warnings-as-errors compilation, Credo, ShellCheck, and Dialyzer all passed; exit 0.
- `direnv exec . just docker-build`: rebuilt `context-bot:local` successfully, image SHA `2971730315b86ac8b53c6a1f3b03266d985967b2d7cdfcf9a8b6ad0d8799a8b7`; exit 0.
- Final-image SQLite smoke: `sqlite3 --version` returned 3.46.1.
- Final disabled-container smoke: migrations completed and `GET /health` returned HTTP 200 with `bot.enabled=false` and `bot.session="disabled"`.
- No Fly, Bluesky, or Anthropic request was made.

## Fix round 2

### Review findings addressed

- Bitwarden values are rejected in `jq` unless they are nonempty strings without decoded LF, CR,
  or NUL characters. Validation happens before command substitution, preventing Bash from silently
  stripping NUL and preventing newline-delimited Fly import injection.
- `APPVIEW_URL` is pinned exactly to the reviewed `https://api.bsky.app` origin because Elder-label
  and identity reads are authorization inputs. Alternate AppView trust roots require a future
  design change.
- `POLL_INTERVAL_MS` is bounded to 5,000–3,600,000 ms and
  `NOTIFICATION_PAGE_CAP` to 1–20. Startup rejects values outside those ranges.

### TDD evidence

- RED: decoded empty/LF/CR/NUL Bitwarden values passed the old loader or bypassed the cleanup
  assertion; noncanonical AppView origins and out-of-range polling values were accepted.
- GREEN: the secrets suite rejects all four invalid value forms under a real `set -e` cleanup
  probe, and focused Settings/ReqClient/Application tests passed 34/34 including both range
  endpoints and rejection immediately outside them.

### Fresh verification

- Fresh `direnv exec . just check` outside the filesystem-lock sandbox passed 318 ExUnit tests,
  secrets tests, formatting, warnings-as-errors compilation, Credo, ShellCheck, and Dialyzer with
  0 errors.
- `direnv exec . just docker-build` built image
  `sha256:6f00ebf9e537fe0302bb583ba6388de2d906c5d8ba9b541223127fe7d6e5801a`.
- The rebuilt image reported SQLite 3.46.1 and returned HTTP 200 from `/health` with
  `BOT_ENABLED=false`, `bot.enabled=false`, and `bot.session=disabled` using a temporary database.
- No Fly, Bluesky, or Anthropic request was made.
