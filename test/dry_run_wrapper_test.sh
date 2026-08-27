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
	start_wrapper_with_args "$1" "post reference" "question text"
}

start_wrapper_with_args() {
	context_bot_test_label="$1"
	shift
	rm -f \
		"$context_bot_test_tmp/arguments" \
		"$context_bot_test_tmp/bot-enabled" \
		"$context_bot_test_tmp/child-pid" \
		"$context_bot_test_tmp/cleanup" \
		"$context_bot_test_tmp/erl-options" \
		"$context_bot_test_tmp/ready" \
		"$context_bot_test_tmp/signal"

	set +e
	(
		trap - INT
		exec ./dry-run.sh "$@"
	) >"$context_bot_test_tmp/output-$context_bot_test_label" 2>&1 &
	wrapper_pid=$!
	set -e
}

assert_usage_error() {
	context_bot_test_label="$1"
	shift
	set +e
	./dry-run.sh "$@" >"$context_bot_test_tmp/output-$context_bot_test_label" 2>&1
	wrapper_status=$?
	set -e

	[[ "$wrapper_status" -eq 64 ]] ||
		fail "$context_bot_test_label exited $wrapper_status instead of usage status 64"
	[[ ! -f "$context_bot_test_tmp/ready" ]] ||
		fail "$context_bot_test_label started mix before rejecting usage"
	[[ "$(<"$context_bot_test_tmp/output-$context_bot_test_label")" != *"anthropic-key-test-value"* ]] ||
		fail "$context_bot_test_label leaked the Anthropic key"
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

start_wrapper single
wait_for_file "$context_bot_test_tmp/ready" || fail "dry-run child did not start"
kill -INT "$wrapper_pid"
wait_for_wrapper

[[ "$wrapper_status" -eq 23 ]] || fail "single interrupt did not preserve the child status"
[[ "$(<"$context_bot_test_tmp/signal")" == "term" ]] || fail "SIGINT was not translated to SIGTERM"
[[ "$(<"$context_bot_test_tmp/erl-options")" == *"+B i"* ]] || fail "BEAM was not configured to ignore direct SIGINT"
[[ "$(<"$context_bot_test_tmp/bot-enabled")" == "false" ]] || fail "dry run enabled the public bot"
[[ "$(<"$context_bot_test_tmp/arguments")" == "context_bot.dry_run post reference question text" ]] ||
	fail "dry-run arguments were not forwarded exactly"
[[ "$(<"$context_bot_test_tmp/output-single")" != *"anthropic-key-test-value"* ]] ||
	fail "dry-run wrapper leaked the Anthropic key"

export CONTEXT_BOT_TEST_DELAYED_CLEANUP=1
start_wrapper repeated
wait_for_file "$context_bot_test_tmp/ready" || fail "delayed-cleanup child did not start"
kill -INT "$wrapper_pid"
wait_for_file "$context_bot_test_tmp/signal" || fail "first interrupt did not reach the child"
kill -INT "$wrapper_pid"
wait_for_wrapper
wait_for_file "$context_bot_test_tmp/cleanup" || fail "wrapper exited before delayed cleanup"

[[ "$wrapper_status" -eq 23 ]] || fail "repeated interrupt did not preserve the child status"
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
	fail "interrupt during launch returned $wrapper_status instead of a reaped child status"

if [[ "$wrapper_status" -eq 23 ]]; then
	[[ "$(<"$context_bot_test_tmp/signal")" == "term" ]] ||
		fail "launch interrupt did not reach the initialized child"
fi

if [[ -f "$context_bot_test_tmp/child-pid" ]]; then
	if kill -0 "$(<"$context_bot_test_tmp/child-pid")" 2>/dev/null; then
		fail "launch-race child remained alive after wrapper exit"
	fi
fi

start_wrapper_with_args one-arg "What's missing?"
wait_for_file "$context_bot_test_tmp/ready" || fail "question-only child did not start"
kill -INT "$wrapper_pid"
wait_for_wrapper

[[ "$wrapper_status" -eq 23 ]] || fail "question-only interrupt did not preserve the child status"
[[ "$(<"$context_bot_test_tmp/bot-enabled")" == "false" ]] || fail "question-only dry run enabled the public bot"
[[ "$(<"$context_bot_test_tmp/arguments")" == "context_bot.dry_run What's missing?" ]] ||
	fail "question-only arguments were not forwarded exactly"
[[ "$(<"$context_bot_test_tmp/output-one-arg")" != *"anthropic-key-test-value"* ]] ||
	fail "question-only wrapper leaked the Anthropic key"

rm -f "$context_bot_test_tmp/ready"
assert_usage_error no-args
[[ "$(<"$context_bot_test_tmp/output-no-args")" == *"question"* ]] ||
	fail "zero-argument usage error did not mention a question"

rm -f "$context_bot_test_tmp/ready"
assert_usage_error extra-args "post" "question" "extra"
[[ "$(<"$context_bot_test_tmp/output-extra-args")" == *"question"* ]] ||
	fail "extra-argument usage error did not mention a question"

rm -f "$context_bot_test_tmp/ready"
assert_usage_error lone-at-uri "at://did:plc:alice/app.bsky.feed.post/3abc"
[[ "$(<"$context_bot_test_tmp/output-lone-at-uri")" == *"question"* ]] ||
	fail "lone at-uri usage error did not mention a question"
[[ "$(<"$context_bot_test_tmp/output-lone-at-uri")" != *"did:plc:alice"* ]] ||
	fail "lone at-uri usage error echoed the post reference"

rm -f "$context_bot_test_tmp/ready"
assert_usage_error lone-bsky-url "https://bsky.app/profile/alice.test/post/3abc"
[[ "$(<"$context_bot_test_tmp/output-lone-bsky-url")" == *"question"* ]] ||
	fail "lone bsky.app usage error did not mention a question"
[[ "$(<"$context_bot_test_tmp/output-lone-bsky-url")" != *"alice.test"* ]] ||
	fail "lone bsky.app usage error echoed the post reference"

printf 'dry-run wrapper tests passed\n'
