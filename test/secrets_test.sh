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

success_output="$(
	(
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
