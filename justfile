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
    fi

format:
    mix format
    shfmt -w dry-run.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

format-check:
    mix format --check-formatted
    shfmt -d dry-run.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

lint:
    mix credo --strict
    shellcheck dry-run.sh live-run.sh secrets.sh test/dry_run_wrapper_test.sh test/live_run_wrapper_test.sh test/secrets_test.sh

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

dry-run post question:
    ./dry-run.sh {{quote(post)}} {{quote(question)}}

live-run invocation_url:
    ./live-run.sh {{quote(invocation_url)}}

reprocess invocation_id:
    mix context_bot.reprocess {{quote(invocation_id)}}

docker-build:
    docker build --progress=plain -t context-bot:local .

secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
    printf 'Deployment secrets loaded and validated.\n'

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
