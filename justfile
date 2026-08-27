set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

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
      bash test/secrets_test.sh
      bash test/dry_run_wrapper_test.sh
      bash test/live_run_wrapper_test.sh
      bash test/fly_wrapper_test.sh
    fi

format:
    mix format
    shfmt -w dry-run.sh fly-dashboard.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/fly_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

format-check:
    mix format --check-formatted
    shfmt -d dry-run.sh fly-dashboard.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/fly_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

lint:
    mix credo --strict
    shellcheck dry-run.sh fly-dashboard.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/fly_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

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

[positional-arguments]
dry-run +args:
    #!/usr/bin/env bash
    set -euo pipefail
    ./dry-run.sh "$@"

live-run invocation_url:
    ./live-run.sh {{quote(invocation_url)}}

reprocess invocation_id:
    mix context_bot.reprocess {{quote(invocation_id)}}

# Reprocess one production invocation from its retained response. May publish a Bluesky reply.
fly-reprocess invocation_id:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Check if machine is running (auto_start_machines may be enabled, but explicit start is safer)
    if ! fly status -a context-bot-social-protocols 2>/dev/null | grep -q "started"; then
      printf 'Fly machine is not running. Starting it...\n' >&2
      fly machine start -a context-bot-social-protocols
      sleep 3
    fi
    
    fly ssh console -a context-bot-social-protocols --command '/app/bin/context_bot eval "
    Application.ensure_all_started(:ssl)
    Application.load(:context_bot)
    Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = ContextBot.Repo.start_link()
    IO.inspect(ContextBot.Workflow.Reprocessor.reprocess({{quote(invocation_id)}}, now: DateTime.utc_now()))
    "'

# Query production invocation status by ID
fly-invocation invocation_id:
    #!/usr/bin/env bash
    set -euo pipefail
    
    if ! command -v jq >/dev/null 2>&1; then
      printf 'Error: jq is required but not installed. Install with: brew install jq (macOS) or apt-get install jq (Linux)\n' >&2
      exit 1
    fi
    
    result=$(fly ssh console -a context-bot-social-protocols --command "sqlite3 -json /data/context_bot.db 'SELECT id, status, stage, failure_detail, reply_uri, reply_part2_uri, actor_handle, invocation_uri, dry_run, inserted_at, updated_at FROM invocations WHERE id = {{quote(invocation_id)}};'")
    
    if [[ -z "$result" || "$result" == "[]" ]]; then
      printf 'Error: Invocation %s not found\n' {{quote(invocation_id)}} >&2
      exit 1
    fi
    
    printf '%s\n' "$result" | jq '.[0] | if .failure_detail != null and (.failure_detail | type == "string" and startswith("{")) then .failure_detail |= fromjson else . end'

# Open the 6PN-only operator dashboard in Google Chrome.
# Remote: http://context-bot-social-protocols.internal:4001/invocations
# Local via fly proxy: http://127.0.0.1:4001/invocations (Ctrl-C stops the proxy)
fly-dashboard:
    ./fly-dashboard.sh

docker-build:
    docker build --progress=plain -t context-bot:local .

secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
    printf 'Deployment secrets loaded and validated.\n'

secrets-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    set +x
    source ./secrets.sh FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
    printf '%s\n' \
      "SECRET_KEY_BASE=$SECRET_KEY_BASE" \
      "BOT_APP_PASSWORD=$BOT_APP_PASSWORD" \
      "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" | fly secrets import
    printf 'Runtime secrets synchronized to Fly.\n'

deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    set +x
    source ./secrets.sh FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
    printf '%s\n' \
      "SECRET_KEY_BASE=$SECRET_KEY_BASE" \
      "BOT_APP_PASSWORD=$BOT_APP_PASSWORD" \
      "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" | fly secrets import --stage
    fly deploy

fly-status:
    fly status

fly-logs:
    fly logs
