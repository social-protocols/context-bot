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
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"}]}'
		}
		set +e
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh"
		partial_status=$?
		set -e
		[[ "$partial_status" -ne 0 ]] || fail "partial item unexpectedly succeeded"
		[[ -z "${FLY_API_TOKEN:-}" ]] || fail "partial Fly token remained exported"
		[[ -z "${SECRET_KEY_BASE:-}" ]] || fail "partial secret key remained exported"
		[[ -z "${BOT_APP_PASSWORD:-}" ]] || fail "partial bot password remained exported"
		[[ -z "${ANTHROPIC_API_KEY:-}" ]] || fail "partial Anthropic key remained exported"
		[[ -z "${context_bot_bitwarden_item:-}" ]] || fail "Bitwarden payload remained in the shell"
		[[ -z "${context_bot_secret_value:-}" ]] || fail "temporary secret remained in the shell"
		[[ -z "${context_bot_bot_app_password:-}" ]] || fail "temporary bot password remained in the shell"
		[[ -z "${context_bot_anthropic_api_key:-}" ]] || fail "temporary Anthropic key remained in the shell"
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
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"},{"name":"IGNORED","value":"ignored-value"}]}'
		}
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh"
		[[ "$FLY_API_TOKEN" == "fly-test-value" ]]
		[[ "$SECRET_KEY_BASE" == "secret-key-test-value" ]]
		[[ "$BOT_APP_PASSWORD" == "app-password-test-value" ]]
		[[ "$ANTHROPIC_API_KEY" == "anthropic-key-test-value" ]]
		[[ -z "${IGNORED:-}" ]]
		[[ -z "${context_bot_bitwarden_item:-}" ]]
		[[ -z "${context_bot_secret_value:-}" ]]
	) 2>&1
)"

[[ "$success_output" != *"fly-test-value"* ]] || fail "Fly token leaked to output"
[[ "$success_output" != *"secret-key-test-value"* ]] || fail "secret key leaked to output"
[[ "$success_output" != *"app-password-test-value"* ]] || fail "bot password leaked to output"
[[ "$success_output" != *"anthropic-key-test-value"* ]] || fail "Anthropic key leaked to output"
[[ "$success_output" != *"ignored-value"* ]] || fail "ignored field leaked to output"

expected_success_output="$(
	cat <<'EOF'
secrets: loaded FLY_API_TOKEN
secrets: loaded SECRET_KEY_BASE
secrets: loaded BOT_APP_PASSWORD
secrets: loaded ANTHROPIC_API_KEY
EOF
)"

[[ "$success_output" == "$expected_success_output" ]] ||
	fail "success output did not contain only exported secret names"

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/context-bot-secrets-test.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"

cat >"$test_tmp/bin/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "get item test-item" ]]
printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"}]}'
EOF

cat >"$test_tmp/bin/fly" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FLY_API_TOKEN:-}" == "fly-test-value" ]]

case "${1:-}" in
secrets)
	[[ "$#" -eq 6 ]]
	[[ "$2" == "set" ]]
	[[ "$3" == "--stage" ]]
	[[ "$4" == "SECRET_KEY_BASE=secret-key-test-value" ]]
	[[ "$5" == "BOT_APP_PASSWORD=app-password-test-value" ]]
	[[ "$6" == "ANTHROPIC_API_KEY=anthropic-key-test-value" ]]
	printf 'secrets\n' >>"$CONTEXT_BOT_FLY_LOG"
	;;
deploy)
	[[ "$#" -eq 1 ]]
	printf 'deploy\n' >>"$CONTEXT_BOT_FLY_LOG"
	;;
*)
	exit 64
	;;
esac
EOF

chmod +x "$test_tmp/bin/bw" "$test_tmp/bin/fly"
: >"$test_tmp/fly.log"

deploy_output="$(
	PATH="$test_tmp/bin:$PATH" \
		BITWARDEN_ITEM_ID="test-item" \
		CONTEXT_BOT_FLY_LOG="$test_tmp/fly.log" \
		just --justfile "$project_root/justfile" --working-directory "$project_root" deploy 2>&1
)"

[[ "$deploy_output" != *"fly-test-value"* ]] || fail "deploy leaked the Fly token"
[[ "$deploy_output" != *"secret-key-test-value"* ]] || fail "deploy leaked the secret key"
[[ "$deploy_output" != *"app-password-test-value"* ]] || fail "deploy leaked the bot password"
[[ "$deploy_output" != *"anthropic-key-test-value"* ]] || fail "deploy leaked the Anthropic key"
[[ "$(cat "$test_tmp/fly.log")" == $'secrets\ndeploy' ]] ||
	fail "deploy did not stage exactly the application secrets before deploying"

printf 'secrets tests passed\n'
