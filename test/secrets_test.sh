#!/usr/bin/env bash
# Test scenarios intentionally isolate environment changes in subshells.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

# `just` intentionally loads a developer's ignored `.env`; tests must not inherit those names.
unset FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

anthropic_only_output="$(
	(
		export BITWARDEN_ITEM_ID="test-item"
		bw() {
			printf '%s\n' '{"fields":[{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"}]}'
		}
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" ANTHROPIC_API_KEY ANTHROPIC_API_KEY
		[[ "$ANTHROPIC_API_KEY" == "anthropic-key-test-value" ]]
		[[ -z "${FLY_API_TOKEN+x}" ]]
		[[ -z "${SECRET_KEY_BASE+x}" ]]
		[[ -z "${BOT_APP_PASSWORD+x}" ]]
	) 2>&1
)"

[[ "$anthropic_only_output" == "secrets: loaded ANTHROPIC_API_KEY" ]] ||
	fail "Anthropic-only loading did not export exactly the requested secret"
[[ "$anthropic_only_output" != *"anthropic-key-test-value"* ]] ||
	fail "Anthropic-only loading leaked the secret value"

if empty_request_output="$(
	(
		export BITWARDEN_ITEM_ID="test-item"
		bw() { exit 99; }
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh"
	) 2>&1
)"; then
	fail "secrets.sh accepted an empty request"
fi
[[ "$empty_request_output" == *"at least one secret name is required"* ]] ||
	fail "empty-request error was not actionable"

if unsupported_output="$(
	(
		export BITWARDEN_ITEM_ID="test-item"
		bw() { exit 99; }
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" NOT_A_SECRET
	) 2>&1
)"; then
	fail "secrets.sh accepted an unsupported secret name"
fi
[[ "$unsupported_output" == *"unsupported secret name: NOT_A_SECRET"* ]] ||
	fail "unsupported-secret error was not actionable"

if missing_output="$(
	(
		unset BITWARDEN_ITEM_ID
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" FLY_API_TOKEN
	) 2>&1
)"; then
	fail "secrets.sh succeeded without BITWARDEN_ITEM_ID"
fi

[[ "$missing_output" == *"BITWARDEN_ITEM_ID is required"* ]] ||
	fail "missing item id error was not actionable"

set +e
errexit_cleanup_output="$(
	CONTEXT_BOT_PROJECT_ROOT="$project_root" bash -c '
		set -euo pipefail
		export BITWARDEN_ITEM_ID="test-item"
		bw() {
			printf "%s\n" '\''{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"}]}'\''
		}
		trap '\''
			status=$?
			[[ "$status" -ne 0 ]] || exit 90
			for variable in FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY context_bot_bitwarden_item context_bot_secret_name context_bot_secret_value context_bot_fly_api_token context_bot_secret_key_base context_bot_bot_app_password context_bot_anthropic_api_key; do
				if [[ -n "${!variable+x}" ]]; then
					exit 91
				fi
			done
			for function_name in context_bot_secrets_fail context_bot_secrets_cleanup context_bot_secrets_restore_xtrace context_bot_secrets_abort; do
				if declare -F "$function_name" >/dev/null; then
					exit 92
				fi
			done
			printf "errexit cleanup verified\n"
		'\'' EXIT
		# shellcheck source=secrets.sh
		source "$CONTEXT_BOT_PROJECT_ROOT/secrets.sh" FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
		printf "unreachable\n"
	' 2>&1
)"
errexit_cleanup_status=$?
set -e

[[ "$errexit_cleanup_status" -ne 0 ]] || fail "partial payload succeeded under errexit"
[[ "$errexit_cleanup_output" == *"errexit cleanup verified"* ]] ||
	fail "errexit exited before secret cleanup completed"
[[ "$errexit_cleanup_output" != *"fly-test-value"* ]] || fail "errexit leaked the Fly token"
[[ "$errexit_cleanup_output" != *"secret-key-test-value"* ]] || fail "errexit leaked the secret key"
[[ "$errexit_cleanup_output" != *"app-password-test-value"* ]] || fail "errexit leaked the bot password"

for invalid_json_value in '""' '"line\nfeed"' '"carriage\rreturn"' '"nul\u0000byte"'; do
	set +e
	invalid_value_output="$(
		CONTEXT_BOT_PROJECT_ROOT="$project_root" \
			CONTEXT_BOT_INVALID_JSON_VALUE="$invalid_json_value" \
			bash -c '
				set -euo pipefail
				export BITWARDEN_ITEM_ID="test-item"
				bw() {
					printf '\''{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":%s}]}\n'\'' "$CONTEXT_BOT_INVALID_JSON_VALUE"
				}
				trap '\''
					status=$?
					[[ "$status" -ne 0 ]] || exit 94
					for variable in FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY context_bot_bitwarden_item context_bot_secret_value context_bot_anthropic_api_key; do
						[[ -z "${!variable+x}" ]] || exit 95
					done
					printf "invalid value cleanup verified\n"
				'\'' EXIT
				# shellcheck source=secrets.sh
				source "$CONTEXT_BOT_PROJECT_ROOT/secrets.sh" FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
			' 2>&1
	)"
	invalid_value_status=$?
	set -e

	[[ "$invalid_value_status" -ne 0 ]] || fail "invalid Bitwarden value unexpectedly succeeded"
	[[ "$invalid_value_output" == *"invalid value cleanup verified"* ]] ||
		fail "invalid Bitwarden value bypassed cleanup"
	[[ "$invalid_value_output" != *"fly-test-value"* ]] || fail "invalid value leaked Fly token"
	[[ "$invalid_value_output" != *"secret-key-test-value"* ]] || fail "invalid value leaked secret key"
	[[ "$invalid_value_output" != *"app-password-test-value"* ]] || fail "invalid value leaked bot password"
done

if ! partial_output="$(
	(
		# Each test scenario intentionally has an isolated environment.
		export BITWARDEN_ITEM_ID="test-item"
		# shellcheck disable=SC2329
		bw() {
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"}]}'
		}
		set +e
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
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
		# shellcheck disable=SC2030
		export BITWARDEN_ITEM_ID="test-item"
		# shellcheck disable=SC2329
		bw() {
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"},{"name":"IGNORED","value":"ignored-value"}]}'
		}
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
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

xtrace_output="$(
	(
		export BITWARDEN_ITEM_ID="test-item"
		# shellcheck disable=SC2329
		bw() {
			printf '%s\n' '{"fields":[{"name":"FLY_API_TOKEN","value":"fly-test-value"},{"name":"SECRET_KEY_BASE","value":"secret-key-test-value"},{"name":"BOT_APP_PASSWORD","value":"app-password-test-value"},{"name":"ANTHROPIC_API_KEY","value":"anthropic-key-test-value"}]}'
		}
		set -x
		# shellcheck source=secrets.sh
		source "$project_root/secrets.sh" FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
		case "$-" in
		*x*) ;;
		*) exit 93 ;;
		esac
		set +x
		[[ "$FLY_API_TOKEN" == "fly-test-value" ]]
		[[ "$SECRET_KEY_BASE" == "secret-key-test-value" ]]
		[[ "$BOT_APP_PASSWORD" == "app-password-test-value" ]]
		[[ "$ANTHROPIC_API_KEY" == "anthropic-key-test-value" ]]
	) 2>&1
)"

[[ "$xtrace_output" != *"fly-test-value"* ]] || fail "xtrace leaked the Fly token"
[[ "$xtrace_output" != *"secret-key-test-value"* ]] || fail "xtrace leaked the secret key"
[[ "$xtrace_output" != *"app-password-test-value"* ]] || fail "xtrace leaked the bot password"
[[ "$xtrace_output" != *"anthropic-key-test-value"* ]] || fail "xtrace leaked the Anthropic key"

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
	[[ "$#" -eq 3 ]]
	[[ "$2" == "import" ]]
	[[ "$3" == "--stage" ]]
	secret_import="$(cat)"
	expected_import="$(printf '%s\n' \
		'SECRET_KEY_BASE=secret-key-test-value' \
		'BOT_APP_PASSWORD=app-password-test-value' \
		'ANTHROPIC_API_KEY=anthropic-key-test-value')"
	[[ "$secret_import" == "$expected_import" ]]
	[[ "$secret_import" != *"FLY_API_TOKEN"* ]]
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
