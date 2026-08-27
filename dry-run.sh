#!/usr/bin/env bash
set -euo pipefail

context_bot_looks_like_post_reference() {
	case "$1" in
	at://* | https://bsky.app/* | http://bsky.app/*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

if [[ "$#" -eq 1 ]]; then
	if context_bot_looks_like_post_reference "$1"; then
		printf 'dry-run: a post reference also needs a question\n' >&2
		exit 64
	fi
elif [[ "$#" -ne 2 ]]; then
	printf 'dry-run: expected a question, or a post and question\n' >&2
	exit 64
fi

# The recipe always runs this wrapper from the repository root.
# shellcheck disable=SC1091
source ./secrets.sh ANTHROPIC_API_KEY

context_bot_child_pid=""
context_bot_interrupt_pending=false
context_bot_forwarding_interrupt=false

# Invoked indirectly by the shell trap below.
# shellcheck disable=SC2329
context_bot_forward_interrupt() {
	context_bot_interrupt_pending=true

	if [[ -z "$context_bot_child_pid" || "$context_bot_forwarding_interrupt" == true ]]; then
		return
	fi

	context_bot_forwarding_interrupt=true
	trap '' INT TERM
	kill -TERM "$context_bot_child_pid" 2>/dev/null || true
	set +e
	wait "$context_bot_child_pid"
	context_bot_child_status=$?
	set -e
	exit "$context_bot_child_status"
}

trap context_bot_forward_interrupt INT TERM

ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +B i" \
	BOT_ENABLED=false mix context_bot.dry_run "$@" &

if [[ "${CONTEXT_BOT_TEST_INTERRUPT_BEFORE_PID:-}" == "1" ]]; then
	kill -INT "$BASHPID"
fi

context_bot_child_pid=$!

if [[ "$context_bot_interrupt_pending" == true ]]; then
	context_bot_forward_interrupt
fi

set +e
wait "$context_bot_child_pid"
context_bot_child_status=$?
set -e

trap - INT TERM
exit "$context_bot_child_status"
