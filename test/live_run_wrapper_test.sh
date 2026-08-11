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
	printf '%s\n' '{"fields":[{"name":"BOT_APP_PASSWORD","value":"bot-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"}]}'
}

mix() {
	trap '' INT
	trap '
		printf "term\n" >"$CONTEXT_BOT_TEST_TMP/signal"
		if [[ "${CONTEXT_BOT_TEST_DELAYED_CLEANUP:-}" == "1" ]]; then
			sleep 1
			printf "cleanup\n" >"$CONTEXT_BOT_TEST_TMP/cleanup"
		fi
		exit 23
	' TERM
	printf '%s\n' "$ELIXIR_ERL_OPTIONS" >"$CONTEXT_BOT_TEST_TMP/erl-options"
	printf '%s\n' "$BOT_ENABLED" >"$CONTEXT_BOT_TEST_TMP/bot-enabled"
	printf '%s\n' "$CONTEXT_BOT_LIVE_RUN" >"$CONTEXT_BOT_TEST_TMP/live-run"
	printf '%s\n' "$CONTEXT_BOT_LIVE_DATABASE_PATH" >"$CONTEXT_BOT_TEST_TMP/live-database"
	printf '%s\n' "$*" >"$CONTEXT_BOT_TEST_TMP/arguments"
	printf '%s\n' "$BASHPID" >"$CONTEXT_BOT_TEST_TMP/child-pid"
	printf 'ready\n' >"$CONTEXT_BOT_TEST_TMP/ready"
	for _attempt in {1..200}; do
		sleep 0.05
	done
	exit 99
}

export -f bw mix

cd "$project_root"

start_wrapper() {
	context_bot_test_label="$1"
	rm -f \
		"$context_bot_test_tmp/arguments" \
		"$context_bot_test_tmp/bot-enabled" \
		"$context_bot_test_tmp/child-pid" \
		"$context_bot_test_tmp/cleanup" \
		"$context_bot_test_tmp/erl-options" \
		"$context_bot_test_tmp/live-database" \
		"$context_bot_test_tmp/live-run" \
		"$context_bot_test_tmp/ready" \
		"$context_bot_test_tmp/signal"

	set +e
	(
		trap - INT
		exec ./live-run.sh "https://bsky.app/profile/actor.test/post/3abc"
	) >"$context_bot_test_tmp/output-$context_bot_test_label" 2>&1 &
	wrapper_pid=$!
	set -e
}

wait_for_file() {
	context_bot_test_file="$1"

	for _attempt in {1..100}; do
		[[ -f "$context_bot_test_file" ]] && return 0
		sleep 0.05
	done

	return 1
}

wait_for_wrapper() {
	set +e
	wait "$wrapper_pid"
	wrapper_status=$?
	set -e
}

if ./live-run.sh >/dev/null 2>&1; then
	fail "live-run wrapper accepted no arguments"
fi

if ./live-run.sh one two >/dev/null 2>&1; then
	fail "live-run wrapper accepted multiple arguments"
fi

start_wrapper single
wait_for_file "$context_bot_test_tmp/ready" || fail "live-run child did not start"
kill -INT "$wrapper_pid"
wait_for_wrapper

[[ "$wrapper_status" -eq 23 ]] || fail "single interrupt did not preserve the child status"
[[ "$(<"$context_bot_test_tmp/signal")" == "term" ]] || fail "SIGINT was not translated to SIGTERM"
[[ "$(<"$context_bot_test_tmp/erl-options")" == *"+B i"* ]] || fail "BEAM did not ignore direct SIGINT"
[[ "$(<"$context_bot_test_tmp/bot-enabled")" == "false" ]] || fail "live run enabled the poller"
[[ "$(<"$context_bot_test_tmp/live-run")" == "true" ]] || fail "live run mode was not exported"
[[ "$(<"$context_bot_test_tmp/live-database")" == "data/live-demo.db" ]] ||
	fail "live run did not select the isolated database"
[[ "$(<"$context_bot_test_tmp/arguments")" == "context_bot.live_run https://bsky.app/profile/actor.test/post/3abc" ]] ||
	fail "live-run arguments were not forwarded exactly"
[[ "$(<"$context_bot_test_tmp/output-single")" != *"anthropic-key-test-value"* ]] || fail "wrapper leaked the Anthropic key"
[[ "$(<"$context_bot_test_tmp/output-single")" != *"bot-password-test-value"* ]] || fail "wrapper leaked the bot password"

export CONTEXT_BOT_LIVE_DATABASE_PATH="data/operator-override.db"
start_wrapper override
wait_for_file "$context_bot_test_tmp/ready" || fail "override child did not start"
kill -INT "$wrapper_pid"
wait_for_wrapper
[[ "$(<"$context_bot_test_tmp/live-database")" == "data/operator-override.db" ]] || fail "database override was lost"
unset CONTEXT_BOT_LIVE_DATABASE_PATH

export CONTEXT_BOT_TEST_DELAYED_CLEANUP=1
start_wrapper repeated
wait_for_file "$context_bot_test_tmp/ready" || fail "delayed-cleanup child did not start"
kill -INT "$wrapper_pid"
wait_for_file "$context_bot_test_tmp/signal" || fail "first interrupt did not reach the child"
kill -INT "$wrapper_pid"
wait_for_wrapper
wait_for_file "$context_bot_test_tmp/cleanup" || fail "wrapper exited before delayed cleanup"
[[ "$wrapper_status" -eq 23 ]] || fail "repeated interrupt did not preserve child status"
unset CONTEXT_BOT_TEST_DELAYED_CLEANUP

export CONTEXT_BOT_TEST_INTERRUPT_BEFORE_PID=1
start_wrapper launch-race
unset CONTEXT_BOT_TEST_INTERRUPT_BEFORE_PID
wait_for_wrapper

if [[ "$wrapper_status" -ne 23 && "$wrapper_status" -ne 143 ]]; then
	if wait_for_file "$context_bot_test_tmp/child-pid"; then
		kill -TERM "$(<"$context_bot_test_tmp/child-pid")" 2>/dev/null || true
	fi
fi

[[ "$wrapper_status" -eq 23 || "$wrapper_status" -eq 143 ]] ||
	fail "launch interrupt returned $wrapper_status instead of a reaped child status"

if [[ -f "$context_bot_test_tmp/child-pid" ]] && kill -0 "$(<"$context_bot_test_tmp/child-pid")" 2>/dev/null; then
	fail "launch-race child remained alive after wrapper exit"
fi

printf 'live-run wrapper tests passed\n'
