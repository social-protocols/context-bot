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
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh"
	) 2>&1
)"; then
	fail "secrets.sh succeeded without BITWARDEN_ITEM_ID"
fi

[[ "$missing_output" == *"BITWARDEN_ITEM_ID is required"* ]] ||
	fail "missing item id error was not actionable"

if ! partial_output="$(
	(
		# Each test scenario intentionally has an isolated environment.
		# shellcheck disable=SC2030
		export BITWARDEN_ITEM_ID="test-item"
		# shellcheck disable=SC2329
		bw() {
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"}]}'
		}
		set +e
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh"
		partial_status=$?
		set -e
		[[ "$partial_status" -ne 0 ]] || fail "partial item unexpectedly succeeded"
		[[ -z "${FLY_API_TOKEN:-}" ]] || fail "partial Fly token remained exported"
		[[ -z "${SECRET_KEY_BASE:-}" ]] || fail "partial secret key remained exported"
		[[ -z "${context_bot_bitwarden_item:-}" ]] || fail "Bitwarden payload remained in the shell"
		[[ -z "${context_bot_secret_value:-}" ]] || fail "temporary secret remained in the shell"
		if declare -F context_bot_secrets_fail >/dev/null; then
			fail "secret helper function remained in the shell"
		fi
	) 2>&1
)"; then
	printf '%s\n' "$partial_output" >&2
	exit 1
fi

success_output="$(
	(
		# Each test scenario intentionally has an isolated environment.
		# shellcheck disable=SC2031
		export BITWARDEN_ITEM_ID="test-item"
		# shellcheck disable=SC2329
		bw() {
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"IGNORED","value":"ignored-value"}]}'
		}
		# shellcheck source=secrets.sh
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
