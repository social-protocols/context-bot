# Repository Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, API-only Phoenix scaffold for the context bot, with Devbox/direnv, SQLite, a health endpoint, Bitwarden-backed Fly deployment commands, and project-specific agent guidance.

**Architecture:** Use one conventional Phoenix application (`context_bot`) with Ecto and SQLite, no UI stack, and no speculative bot-domain modules. Devbox owns every CLI used by project recipes; `just` is the public command interface; a generated OTP release runs as one Fly Machine with `/data` mounted for SQLite.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix/phx_new 1.8.9, Ecto, ecto_sqlite3, Bandit, ExUnit, Credo, Dialyxir, Devbox, direnv, just, Docker, Fly.io, Bitwarden CLI, Bash.

## Global Constraints

- The application name is `context_bot`; the Elixir namespace is `ContextBot`.
- Generate no HTML, LiveView, frontend assets, dashboard, gettext, or mailer.
- Do not create bot-specific domain modules, schemas, migrations, workers, or boundaries.
- SQLite is operational outbox/cache state, not the intended canonical audit trail.
- Development uses `data/context_bot_dev.db`; tests use partition-aware databases under `data/`; production requires `/data/context_bot.db`.
- The Fly app is `context-bot-social-protocols` in `den`, with one shared-CPU, 1 GB Machine and one `context_bot_data` volume.
- Declare `bitwarden-cli@latest`; do not add a requested Bitwarden CLI version pin.
- Never commit credentials or print secret values.
- Use generated-code/configuration verification for Phoenix/Devbox boilerplate; use strict red-green TDD for custom health and secrets behavior.
- Run all project commands as `direnv exec . <command>` from non-interactive shells.
- Commit each completed task with a concise message and preserve a linear history.

---

## File Map

### Generated Phoenix foundation

- `.formatter.exs` — Mix formatter configuration.
- `mix.exs`, `mix.lock` — application definition and locked Hex dependencies.
- `config/config.exs` — shared endpoint, Repo, JSON, and logger configuration.
- `config/dev.exs`, `config/test.exs`, `config/prod.exs`, `config/runtime.exs` — environment-specific SQLite and endpoint configuration.
- `lib/context_bot.ex` — application namespace documentation only.
- `lib/context_bot/application.ex` — OTP supervision tree.
- `lib/context_bot/repo.ex` — Ecto SQLite repository.
- `lib/context_bot_web.ex` — web-interface macros.
- `lib/context_bot_web/endpoint.ex` — Bandit/Phoenix endpoint.
- `lib/context_bot_web/router.ex` — API router.
- `lib/context_bot_web/telemetry.ex` — Phoenix telemetry supervisor.
- `priv/repo/migrations/.formatter.exs` — migration formatter configuration; no bot migration.
- `test/support/conn_case.ex`, `test/support/data_case.ex`, `test/test_helper.exs` — standard test support.

### Repository workflow

- `devbox.json`, `devbox.lock` — reproducible system toolchain.
- `.envrc` — generated Devbox/direnv bridge.
- `.gitignore` — generated artifacts, databases, local worktrees, secrets, and caches.
- `justfile` — public command interface.

### Custom behavior

- `lib/context_bot_web/controllers/health_controller.ex` — JSON health response.
- `test/context_bot_web/controllers/health_controller_test.exs` — health endpoint contract.
- `secrets.sh` — allowlisted Bitwarden custom-field loader.
- `test/secrets_test.sh` — isolated shell tests using a fake `bw` function.

### Release and deployment

- `lib/context_bot/release.ex` — release-time Ecto migration entrypoint.
- `rel/overlays/bin/migrate`, `rel/overlays/bin/server` — release migration and migration-before-start helpers.
- `rel/overlays/bin/docker-entrypoint` — mounted-volume ownership and privilege-drop wrapper.
- `Dockerfile`, `.dockerignore` — Phoenix-generated multi-stage release image, adjusted for API-only SQLite.
- `fly.toml` — one-Machine Fly configuration and `/health` check.

### Documentation

- `README.md` — project purpose and developer/deployment quick start.
- `AGENTS.md` — canonical instructions adapted from Malasaña Method.
- `CLAUDE.md` — pointer to `AGENTS.md`.

---

### Task 1: Reproducible Toolchain and Phoenix Foundation

**Files:**
- Create: `devbox.json`
- Create: `devbox.lock`
- Create: `.envrc`
- Create: `.formatter.exs`
- Create: `mix.exs`
- Create: `mix.lock`
- Create: `config/config.exs`
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Create: `config/prod.exs`
- Create: `config/runtime.exs`
- Create: `lib/context_bot.ex`
- Create: `lib/context_bot/application.ex`
- Create: `lib/context_bot/repo.ex`
- Create: `lib/context_bot_web.ex`
- Create: `lib/context_bot_web/endpoint.ex`
- Create: `lib/context_bot_web/router.ex`
- Create: `lib/context_bot_web/telemetry.ex`
- Create: `priv/repo/migrations/.formatter.exs`
- Create: `test/support/conn_case.ex`
- Create: `test/support/data_case.ex`
- Create: `test/test_helper.exs`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: Devbox installed on the host; no global Elixir, Erlang, or Phoenix installation.
- Produces: a compiling `:context_bot` OTP application with `ContextBot.Repo` and `ContextBotWeb.Endpoint` available to later tasks.

This task is the approved generated-code/configuration exception. Verify the generator output and dependency graph directly; custom behavior begins test-first in Task 3.

- [ ] **Step 1: Add the Devbox definition**

Create `devbox.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/jetify-com/devbox/main/.schema/devbox.schema.json",
  "packages": [
    "elixir@1.20",
    "erlang@28",
    "sqlite@latest",
    "just@latest",
    "flyctl@latest",
    "bitwarden-cli@latest",
    "docker-client@latest",
    "git@latest",
    "jq@latest",
    "curl@latest",
    "shellcheck@latest",
    "shfmt@latest"
  ],
  "shell": {
    "init_hook": [
      "mix local.hex --force",
      "mix local.rebar --force",
      "if [ -f mix.exs ]; then mix deps.get; fi"
    ]
  }
}
```

- [ ] **Step 2: Resolve Devbox and generate direnv integration**

Run:

```bash
devbox install
devbox generate direnv
direnv allow
```

Expected: `devbox.lock` and `.envrc` are created; entering the directory exposes Elixir 1.20 and OTP 28.

- [ ] **Step 3: Generate the API-only Phoenix application**

Run the generator in a validated temporary directory so it cannot overwrite the committed design documents, then copy only its generated tree into the repository:

```bash
direnv exec . mix archive.install hex phx_new 1.8.9 --force
scaffold_dir="$(mktemp -d /tmp/context-bot-phoenix.XXXXXX)"
direnv exec . mix phx.new "$scaffold_dir" \
  --app context_bot \
  --module ContextBot \
  --database sqlite3 \
  --adapter bandit \
  --no-assets \
  --no-dashboard \
  --no-gettext \
  --no-html \
  --no-mailer \
  --no-agents-md \
  --no-install
cp -R "$scaffold_dir"/. .
```

Expected: Phoenix files are added without changing `docs/superpowers/**` or `.git/`.

- [ ] **Step 4: Add code-quality dependencies and enforce Elixir 1.20**

In `mix.exs`, set:

```elixir
elixir: "~> 1.20"
```

Add to `deps/0`:

```elixir
{:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
{:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false}
```

Run:

```bash
direnv exec . mix deps.get
```

Expected: `mix.lock` resolves Phoenix 1.8.9, ecto_sqlite3 0.24.x, Credo 1.7.19, and Dialyxir 1.4.7 without vulnerable Phoenix 1.8.8 or older.

- [ ] **Step 5: Complete ignores**

Keep the Phoenix-generated entries and add:

```gitignore
/.devbox/
/.direnv/
/.elixir_ls/
/.worktrees/
/.dialyzer_plt*
/data/
/.env
/.env.*
!/.env.example
```

- [ ] **Step 6: Verify the generated foundation**

Run:

```bash
direnv exec . elixir --version
direnv exec . mix phx.new --version
direnv exec . mix compile --warnings-as-errors
git diff --check
```

Expected: Elixir reports 1.20.x on OTP 28, Phoenix reports 1.8.9, compilation exits 0 without warnings, and the diff check is empty.

- [ ] **Step 7: Commit**

```bash
git add devbox.json devbox.lock .envrc .formatter.exs .gitignore mix.exs mix.lock config lib priv test
git commit -m "chore: scaffold Phoenix application"
```

---

### Task 2: SQLite Runtime Configuration and Just Commands

**Files:**
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Create: `justfile`

**Interfaces:**
- Consumes: `ContextBot.Repo` from Task 1.
- Produces: development/test/production database-path contracts and stable `just` recipes used by every later task.

This task changes configuration only; verify it by creating, migrating, and opening the databases rather than adding declaration-level tests.

- [ ] **Step 1: Configure worktree-local development SQLite**

In `config/dev.exs`, configure the Repo with:

```elixir
config :context_bot, ContextBot.Repo,
  database: Path.expand("../data/context_bot_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
```

- [ ] **Step 2: Configure partition-aware test SQLite**

At the top of `config/test.exs`, add:

```elixir
partition = System.get_env("MIX_TEST_PARTITION")
database_name = "context_bot_test#{partition}.db"
```

Configure the Repo with:

```elixir
config :context_bot, ContextBot.Repo,
  database: Path.expand("../data/#{database_name}", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
```

- [ ] **Step 3: Configure production SQLite at runtime**

Inside the `if config_env() == :prod` block in `config/runtime.exs`, replace database URL configuration with:

```elixir
database_path =
  System.get_env("DATABASE_PATH") ||
    raise "environment variable DATABASE_PATH is missing"

config :context_bot, ContextBot.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
```

Keep Phoenix's generated `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, and IPv6 socket configuration, but do not add PostgreSQL-only Ecto options.

- [ ] **Step 4: Create the command interface**

Create `justfile` with Bash strict mode and these recipe bodies:

```just
set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

help:
    @just --list --unsorted

setup:
    mix local.hex --force
    mix local.rebar --force
    mix deps.get
    mkdir -p data
    mix ecto.setup

dev: setup
    mix phx.server

test path="":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p data
    if [[ -n "{{path}}" ]]; then
      mix test "{{path}}"
    else
      mix test
      # Task 4: bash test/secrets_test.sh
    fi

format:
    mix format
    # Task 4: shfmt -w secrets.sh test/secrets_test.sh

format-check:
    mix format --check-formatted
    # Task 4: shfmt -d secrets.sh test/secrets_test.sh

lint:
    mix credo --strict
    # Task 4: shellcheck secrets.sh test/secrets_test.sh

typecheck:
    mix dialyzer

check: format-check
    MIX_ENV=test mix compile --warnings-as-errors
    just lint
    just test
    just typecheck

db-create:
    mkdir -p data
    mix ecto.create

db-migrate:
    mkdir -p data
    mix ecto.migrate

db-reset:
    mkdir -p data
    mix ecto.reset

docker-build:
    docker build --progress=plain -t context-bot:local .

secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh
    printf 'Deployment secrets loaded and validated.\n'

deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh
    fly secrets set --stage SECRET_KEY_BASE="$SECRET_KEY_BASE"
    fly deploy

fly-status:
    fly status

fly-logs:
    fly logs
```

Initially comment out the shell-test and shell-format lines until Task 4 creates those files; uncomment them in Task 4. Do not create dummy scripts just to satisfy the recipes.

- [ ] **Step 5: Verify database lifecycle and recipes**

Run:

```bash
direnv exec . just setup
direnv exec . just db-reset
direnv exec . sqlite3 data/context_bot_dev.db '.databases'
direnv exec . just --list
```

Expected: the development database exists under `data/`, SQLite opens it, and every documented recipe is listed.

- [ ] **Step 6: Commit**

```bash
git add config/dev.exs config/test.exs config/runtime.exs justfile
git commit -m "chore: configure SQLite development workflow"
```

---

### Task 3: Health Endpoint

**Files:**
- Create: `test/context_bot_web/controllers/health_controller_test.exs`
- Create: `lib/context_bot_web/controllers/health_controller.ex`
- Modify: `lib/context_bot_web/router.ex`

**Interfaces:**
- Consumes: `ContextBotWeb.ConnCase` and `ContextBotWeb.Router` from Task 1.
- Produces: `GET /health -> 200 {"status":"ok"}`, used by Fly and local smoke verification.

- [ ] **Step 1: Write the failing endpoint test**

Create:

```elixir
defmodule ContextBotWeb.HealthControllerTest do
  use ContextBotWeb.ConnCase, async: true

  test "GET /health reports that the service is running", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
```

- [ ] **Step 2: Run it and verify RED**

Run:

```bash
direnv exec . mix test test/context_bot_web/controllers/health_controller_test.exs
```

Expected: FAIL with a routing error or HTTP 404 because `/health` does not exist.

- [ ] **Step 3: Implement the minimal controller**

Create:

```elixir
defmodule ContextBotWeb.HealthController do
  use ContextBotWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
```

Add to the API scope in `router.ex`:

```elixir
scope "/", ContextBotWeb do
  pipe_through :api

  get "/health", HealthController, :show
end
```

- [ ] **Step 4: Run it and verify GREEN**

Run:

```bash
direnv exec . mix test test/context_bot_web/controllers/health_controller_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Refactor and verify the full suite**

Run:

```bash
direnv exec . mix format
direnv exec . mix test
```

Expected: all ExUnit tests pass with no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/context_bot_web/controllers/health_controller.ex lib/context_bot_web/router.ex test/context_bot_web/controllers/health_controller_test.exs
git commit -m "feat: add service health endpoint"
```

---

### Task 4: Bitwarden Secret Loading

**Files:**
- Create: `test/secrets_test.sh`
- Create: `secrets.sh`
- Modify: `justfile`

**Interfaces:**
- Consumes: `bw get item ID` JSON with custom fields named `FLY_API_TOKEN` and `SECRET_KEY_BASE`.
- Produces: exported `FLY_API_TOKEN` and `SECRET_KEY_BASE` in the sourcing shell, without printing either value.

- [ ] **Step 1: Write the failing shell test**

Create `test/secrets_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if missing_output="$(
  (
    unset BITWARDEN_ITEM_ID
    # shellcheck source=../secrets.sh
    source "$project_root/secrets.sh"
  ) 2>&1
)"; then
  fail "secrets.sh succeeded without BITWARDEN_ITEM_ID"
fi

[[ "$missing_output" == *"BITWARDEN_ITEM_ID is required"* ]] ||
  fail "missing item id error was not actionable"

success_output="$(
  (
    export BITWARDEN_ITEM_ID="test-item"
    bw() {
      printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"IGNORED","value":"ignored-value"}]}'
    }
    # shellcheck source=../secrets.sh
    source "$project_root/secrets.sh"
    [[ "$FLY_API_TOKEN" == "fly-test-value" ]]
    [[ "$SECRET_KEY_BASE" == "secret-key-test-value" ]]
    [[ -z "${IGNORED:-}" ]]
  ) 2>&1
)"

[[ "$success_output" != *"fly-test-value"* ]] || fail "Fly token leaked to output"
[[ "$success_output" != *"secret-key-test-value"* ]] || fail "secret key leaked to output"
[[ "$success_output" == *"FLY_API_TOKEN"* ]] || fail "loaded secret name was not reported"
[[ "$success_output" == *"SECRET_KEY_BASE"* ]] || fail "loaded secret name was not reported"

printf 'secrets tests passed\n'
```

- [ ] **Step 2: Run it and verify RED**

Run:

```bash
direnv exec . bash test/secrets_test.sh
```

Expected: FAIL because `secrets.sh` does not exist.

- [ ] **Step 3: Implement the allowlisted loader**

Create `secrets.sh`:

```bash
#!/usr/bin/env bash

context_bot_secrets_fail() {
  printf 'secrets: %s\n' "$1" >&2
  return 1
}

if [[ -z "${BITWARDEN_ITEM_ID:-}" ]]; then
  context_bot_secrets_fail "BITWARDEN_ITEM_ID is required"
  return 1 2>/dev/null || exit 1
fi

if ! context_bot_bitwarden_item="$(bw get item "$BITWARDEN_ITEM_ID")"; then
  context_bot_secrets_fail "unable to read Bitwarden item; log in and unlock the vault"
  return 1 2>/dev/null || exit 1
fi

for context_bot_secret_name in FLY_API_TOKEN SECRET_KEY_BASE; do
  if ! context_bot_secret_value="$(
    jq -er --arg name "$context_bot_secret_name" \
      '[.fields[]? | select(.name == $name) | .value][0] // empty' \
      <<<"$context_bot_bitwarden_item"
  )"; then
    context_bot_secrets_fail "missing required custom field: $context_bot_secret_name"
    return 1 2>/dev/null || exit 1
  fi

  printf -v "$context_bot_secret_name" '%s' "$context_bot_secret_value"
  export "$context_bot_secret_name"
  printf 'secrets: loaded %s\n' "$context_bot_secret_name"
done

unset context_bot_bitwarden_item context_bot_secret_name context_bot_secret_value
unset -f context_bot_secrets_fail
```

- [ ] **Step 4: Run it and verify GREEN**

Run:

```bash
direnv exec . bash test/secrets_test.sh
```

Expected: `secrets tests passed`, exit 0, with no test secret value printed.

- [ ] **Step 5: Enable shell coverage in just recipes**

Uncomment the Task 2 lines so:

- `just test` runs `bash test/secrets_test.sh` after ExUnit.
- `just format` runs `shfmt -w secrets.sh test/secrets_test.sh`.
- `just format-check` runs `shfmt -d secrets.sh test/secrets_test.sh`.
- `just lint` runs `shellcheck secrets.sh test/secrets_test.sh`.

Run:

```bash
direnv exec . just format
direnv exec . just lint
direnv exec . just test
```

Expected: formatting is stable, ShellCheck reports no findings, and both ExUnit and shell tests pass.

- [ ] **Step 6: Commit**

```bash
git add secrets.sh test/secrets_test.sh justfile
git commit -m "feat: load deployment secrets from Bitwarden"
```

---

### Task 5: OTP Release, Docker Image, and Fly Configuration

**Files:**
- Create: `lib/context_bot/release.ex`
- Create: `rel/overlays/bin/migrate`
- Create: `rel/overlays/bin/server`
- Create: `rel/overlays/bin/docker-entrypoint`
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `fly.toml`
- Modify: `Dockerfile` only if the generator retains asset-only commands or omits SQLite runtime libraries.

**Interfaces:**
- Consumes: production `DATABASE_PATH`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, and the `/health` endpoint.
- Produces: `/app/bin/docker-entrypoint`, `/app/bin/server`, `/app/bin/migrate`, and a Fly service on internal port 4000.

This task uses Phoenix's release generator; verify the release and container rather than testing generated Docker syntax with source-string assertions.

- [ ] **Step 1: Generate release and Docker files**

Run:

```bash
direnv exec . mix phx.gen.release --docker
```

Expected: Phoenix creates `ContextBot.Release`, release overlay scripts, `Dockerfile`, and `.dockerignore` using the active Elixir 1.20/OTP 28 versions.

- [ ] **Step 2: Make the generated Dockerfile API/SQLite-correct**

Inspect the generated file and make these exact semantic adjustments:

- Remove `mix assets.setup`, `COPY assets assets`, and `mix assets.deploy` lines because the app has no assets.
- Keep Debian/Ubuntu rather than Alpine.
- Ensure the final image installs `libsqlite3-0` and `gosu` in addition to the generated OpenSSL, libstdc++, ncurses, locale, and CA packages.
- Replace `USER nobody` with `ENTRYPOINT ["/app/bin/docker-entrypoint"]`; keep `CMD ["/app/bin/server"]`. The entrypoint drops privileges after preparing the mounted directory.

Run:

```bash
rg -n 'assets|libsqlite|gosu|docker-entrypoint|/app/bin/server' Dockerfile
```

Expected: no asset build steps remain; SQLite, `gosu`, the entrypoint, and server command are present.

- [ ] **Step 3: Run migrations on the mounted Machine and drop privileges**

Replace the generated `rel/overlays/bin/server` with:

```sh
#!/bin/sh
set -eu

/app/bin/migrate
PHX_SERVER=true exec /app/bin/context_bot start
```

Create `rel/overlays/bin/docker-entrypoint`:

```sh
#!/bin/sh
set -eu

if [ "$(id -u)" = "0" ]; then
  mkdir -p /data
  chown nobody:root /data
  exec gosu nobody "$@"
fi

exec "$@"
```

Make both files executable. The entrypoint runs as root only long enough to prepare `/data`, then `gosu` runs the release as `nobody`. The server migrates after the real volume is mounted, avoiding a Fly temporary `release_command` Machine.

- [ ] **Step 4: Add Fly configuration**

Create `fly.toml`:

```toml
app = "context-bot-social-protocols"
primary_region = "den"

[build]
  dockerfile = "Dockerfile"

[env]
  DATABASE_PATH = "/data/context_bot.db"
  PHX_HOST = "context-bot-social-protocols.fly.dev"
  PHX_SERVER = "true"
  PORT = "4000"

[deploy]
  strategy = "immediate"

[[mounts]]
  source = "context_bot_data"
  destination = "/data"
  initial_size = "1gb"
  snapshot_retention = 14

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1
  processes = ["app"]

  [[http_service.checks]]
    grace_period = "10s"
    interval = "15s"
    method = "GET"
    path = "/health"
    timeout = "2s"

[[vm]]
  memory = "1gb"
  cpu_kind = "shared"
  cpus = 1
```

- [ ] **Step 5: Verify release and Fly syntax**

Generate a temporary secret and run:

```bash
secret_key_base="$(direnv exec . mix phx.gen.secret)"
DATABASE_PATH="/tmp/context_bot_release.db" \
PHX_HOST="localhost" \
SECRET_KEY_BASE="$secret_key_base" \
PHX_SERVER="true" \
MIX_ENV=prod \
direnv exec . mix release --overwrite
direnv exec . fly config validate
```

Expected: release assembly and Fly config validation both exit 0.

- [ ] **Step 6: Build and smoke-test the image**

Run:

```bash
direnv exec . just docker-build
```

Smoke-test it:

```bash
smoke_data_dir="$(mktemp -d /tmp/context-bot-data.XXXXXX)"
smoke_secret="$(direnv exec . mix phx.gen.secret)"
smoke_container="context-bot-smoke-$$"
trap 'docker stop "$smoke_container" >/dev/null 2>&1 || true' EXIT
docker run --rm --detach \
  --name "$smoke_container" \
  --publish 4010:4000 \
  --volume "$smoke_data_dir:/data" \
  --env DATABASE_PATH=/data/context_bot.db \
  --env PHX_HOST=localhost \
  --env PHX_SERVER=true \
  --env PORT=4000 \
  --env SECRET_KEY_BASE="$smoke_secret" \
  context-bot:local
for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:4010/health; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error http://127.0.0.1:4010/health
docker exec "$smoke_container" sh -c 'test -w /data && test "$(id -u)" != "0"'
docker stop "$smoke_container"
trap - EXIT
```

Expected: Docker build exits 0, the release migration command succeeds, both health requests return `{"status":"ok"}`, and the non-root release user can write `/data`.

- [ ] **Step 7: Commit**

```bash
git add lib/context_bot/release.ex rel Dockerfile .dockerignore fly.toml
git commit -m "chore: add Fly release deployment"
```

---

### Task 6: Developer and Agent Documentation

**Files:**
- Create: `README.md`
- Create: `AGENTS.md`
- Create: `CLAUDE.md`

**Interfaces:**
- Consumes: the commands and constraints implemented in Tasks 1–5.
- Produces: one human quick start and one canonical agent guide; no runtime interface.

- [ ] **Step 1: Write the README**

Create `README.md`:

````markdown
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

SQLite is operational state and a future outbox/cache. It is not the intended canonical audit trail. Successfully published ATProto records are expected to become the source of truth.

## Deployment

Create the Fly app and one volume before the first deploy:

```bash
fly apps create context-bot-social-protocols
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
````

- [ ] **Step 2: Adapt the Malasaña Method guide**

Create `AGENTS.md`:

````markdown
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
````

- [ ] **Step 3: Add the Claude pointer**

Create `CLAUDE.md`:

```markdown
# CLAUDE.md

See [AGENTS.md](AGENTS.md) for all project guidance. It is the canonical source for environment, worktree, testing, architecture, and deployment instructions.
```

- [ ] **Step 4: Verify documentation against reality**

Run:

```bash
direnv exec . just --list
rg -n -i 'python|conjugat|spanish|svg|astro|website|frontend|liveview' AGENTS.md CLAUDE.md README.md
rg -n 'direnv exec \.|\.worktrees/|just check|SQLite|Bitwarden' AGENTS.md README.md
git diff --check
```

Expected: command names match the justfile; the irrelevant-term scan is empty except deliberate statements that no frontend/LiveView exists; worktree, verification, persistence, and secret guidance are present.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md CLAUDE.md
git commit -m "docs: add project development guide"
```

---

### Task 7: Full Verification and Clean Handoff

**Files:**
- Modify only files required to fix verification failures; do not broaden scope.

**Interfaces:**
- Consumes: all scaffold commands and artifacts.
- Produces: fresh evidence that a new checkout can build, test, run, and package the scaffold.

- [ ] **Step 1: Confirm repository scope**

Run:

```bash
git status --short
find lib -maxdepth 4 -type f | sort
find priv/repo/migrations -maxdepth 2 -type f | sort
```

Expected: no uncommitted changes, no bot-domain modules, and no bot-specific migration files.

- [ ] **Step 2: Verify tool resolution**

Run:

```bash
direnv exec . bash -c 'command -v elixir erl mix sqlite3 just fly bw docker jq curl shellcheck shfmt'
direnv exec . elixir --version
```

Expected: every command resolves inside Devbox; Elixir is 1.20.x and OTP is 28.

- [ ] **Step 3: Run the full quality gate**

Run:

```bash
direnv exec . just check
```

Expected: formatting check, warnings-as-errors compilation, Credo, ShellCheck, ExUnit, secrets shell tests, and Dialyzer all exit 0.

- [ ] **Step 4: Smoke-test the local service**

```bash
direnv exec . just dev >/tmp/context-bot-dev.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT
for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:4000/health; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error http://127.0.0.1:4000/health
kill "$server_pid"
wait "$server_pid" || true
trap - EXIT
```

Expected: both requests return `{"status":"ok"}` and the server process stops cleanly.

- [ ] **Step 5: Verify deployment artifact**

Run:

```bash
direnv exec . fly config validate
direnv exec . just docker-build
smoke_data_dir="$(mktemp -d /tmp/context-bot-data.XXXXXX)"
smoke_secret="$(direnv exec . mix phx.gen.secret)"
smoke_container="context-bot-smoke-$$"
trap 'docker stop "$smoke_container" >/dev/null 2>&1 || true' EXIT
docker run --rm --detach \
  --name "$smoke_container" \
  --publish 4010:4000 \
  --volume "$smoke_data_dir:/data" \
  --env DATABASE_PATH=/data/context_bot.db \
  --env PHX_HOST=localhost \
  --env PHX_SERVER=true \
  --env PORT=4000 \
  --env SECRET_KEY_BASE="$smoke_secret" \
  context-bot:local
for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:4010/health; then
    break
  fi
  sleep 1
done
curl --fail --silent --show-error http://127.0.0.1:4010/health
docker exec "$smoke_container" sh -c 'test -w /data && test "$(id -u)" != "0"'
docker stop "$smoke_container"
trap - EXIT
```

Expected: Fly validation, Docker build, migration, container startup, and container health all succeed.

- [ ] **Step 6: Verify safe secret failure and final Git state**

Run:

```bash
env -u BITWARDEN_ITEM_ID direnv exec . bash -c 'source ./secrets.sh'
git diff --check
git status --short --branch
git log --oneline --decorate -8
```

Expected: the secret command fails non-zero with `BITWARDEN_ITEM_ID is required` and no value output; the diff check is empty; the worktree is clean; history is linear with one commit per task.
