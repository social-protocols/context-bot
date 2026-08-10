#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
	printf 'dry-run: expected a post reference and question\n' >&2
	exit 64
fi

# The recipe always runs this wrapper from the repository root.
# shellcheck disable=SC1091
source ./secrets.sh ANTHROPIC_API_KEY

context_bot_child_pid=""

# Invoked indirectly by the shell trap below.
# shellcheck disable=SC2329
context_bot_forward_interrupt() {
	trap - INT TERM

	if [[ -n "$context_bot_child_pid" ]]; then
		kill -TERM "$context_bot_child_pid" 2>/dev/null || true
		set +e
		wait "$context_bot_child_pid"
		context_bot_child_status=$?
		set -e
		exit "$context_bot_child_status"
	fi

	exit 130
}

trap context_bot_forward_interrupt INT TERM

ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +B i" \
	BOT_ENABLED=false mix context_bot.dry_run "$1" "$2" &
context_bot_child_pid=$!

set +e
wait "$context_bot_child_pid"
context_bot_child_status=$?
set -e

trap - INT TERM
exit "$context_bot_child_status"
