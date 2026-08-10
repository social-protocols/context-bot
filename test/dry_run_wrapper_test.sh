#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context_bot_test_tmp="$(mktemp -d)"
export CONTEXT_BOT_TEST_TMP="$context_bot_test_tmp"

cleanup() {
	rm -rf "$context_bot_test_tmp"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

export BITWARDEN_ITEM_ID="test-item"

bw() {
	printf '%s\n' '{"fields":[{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"}]}'
}

mix() {
	trap '' INT
	trap 'printf "term\n" >"$CONTEXT_BOT_TEST_TMP/signal"; exit 23' TERM
	printf '%s\n' "$ELIXIR_ERL_OPTIONS" >"$CONTEXT_BOT_TEST_TMP/erl-options"
	printf '%s\n' "$BOT_ENABLED" >"$CONTEXT_BOT_TEST_TMP/bot-enabled"
	printf '%s\n' "$*" >"$CONTEXT_BOT_TEST_TMP/arguments"
	printf 'ready\n' >"$CONTEXT_BOT_TEST_TMP/ready"
	while true; do
		sleep 1
	done
}

export -f bw mix

cd "$project_root"

set +e
(
	trap - INT
	exec ./dry-run.sh "post reference" "question text"
) &
wrapper_pid=$!
set -e

for _attempt in {1..100}; do
	[[ -f "$context_bot_test_tmp/ready" ]] && break
	sleep 0.05
done

[[ -f "$context_bot_test_tmp/ready" ]] || fail "dry-run child did not start"
kill -INT "$wrapper_pid"

set +e
wait "$wrapper_pid"
wrapper_status=$?
set -e

[[ "$wrapper_status" -eq 23 ]] || fail "wrapper did not preserve the interrupted child status"
[[ "$(<"$context_bot_test_tmp/signal")" == "term" ]] || fail "SIGINT was not translated to SIGTERM"
[[ "$(<"$context_bot_test_tmp/erl-options")" == *"+B i"* ]] || fail "BEAM was not configured to ignore direct SIGINT"
[[ "$(<"$context_bot_test_tmp/bot-enabled")" == "false" ]] || fail "dry run enabled the public bot"
[[ "$(<"$context_bot_test_tmp/arguments")" == "context_bot.dry_run post reference question text" ]] ||
	fail "dry-run arguments were not forwarded exactly"

printf 'dry-run wrapper tests passed\n'
