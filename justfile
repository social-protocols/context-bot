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
      bash test/secrets_test.sh
    fi

format:
    mix format
    shfmt -w secrets.sh test/secrets_test.sh

format-check:
    mix format --check-formatted
    shfmt -d secrets.sh test/secrets_test.sh

lint:
    mix credo --strict
    shellcheck secrets.sh test/secrets_test.sh

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
    fly secrets set --stage \
      SECRET_KEY_BASE="$SECRET_KEY_BASE" \
      BOT_APP_PASSWORD="$BOT_APP_PASSWORD" \
      ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
    fly deploy

fly-status:
    fly status

fly-logs:
    fly logs
