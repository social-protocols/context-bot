#!/usr/bin/env bash

context_bot_secrets_xtrace_enabled=false

case "$-" in
*x*)
	context_bot_secrets_xtrace_enabled=true
	set +x
	;;
esac

context_bot_secrets_fail() {
	printf 'secrets: %s\n' "$1" >&2
}

context_bot_secrets_cleanup() {
	unset context_bot_bitwarden_item context_bot_secret_name context_bot_secret_value
	unset context_bot_fly_api_token context_bot_secret_key_base
	unset context_bot_bot_app_password context_bot_anthropic_api_key
}

context_bot_secrets_restore_xtrace() {
	if [[ "$context_bot_secrets_xtrace_enabled" == "true" ]]; then
		unset context_bot_secrets_xtrace_enabled
		unset -f context_bot_secrets_fail context_bot_secrets_cleanup
		unset -f context_bot_secrets_restore_xtrace context_bot_secrets_abort
		set -x
	else
		unset context_bot_secrets_xtrace_enabled
		unset -f context_bot_secrets_fail context_bot_secrets_cleanup
		unset -f context_bot_secrets_restore_xtrace context_bot_secrets_abort
	fi
}

context_bot_secrets_abort() {
	context_bot_secrets_fail "$1"
	context_bot_secrets_cleanup
	unset FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY
	context_bot_secrets_restore_xtrace
}

unset FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY

if [[ -z "${BITWARDEN_ITEM_ID:-}" ]]; then
	context_bot_secrets_abort "BITWARDEN_ITEM_ID is required"
	# This file supports both sourcing and direct execution.
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

if ! context_bot_bitwarden_item="$(bw get item "$BITWARDEN_ITEM_ID")"; then
	context_bot_secrets_abort "unable to read Bitwarden item; log in and unlock the vault"
	# shellcheck disable=SC2317
	return 1 2>/dev/null || exit 1
fi

for context_bot_secret_name in FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY; do
	if ! context_bot_secret_value="$(
		jq -er --arg name "$context_bot_secret_name" \
			'([.fields[]? | select(.name == $name) | .value][0] // empty)
			 | select(type == "string")
			 | select(length > 0)
			 | select(index("\n") == null and index("\r") == null and index("\u0000") == null)' \
			<<<"$context_bot_bitwarden_item"
	)"; then
		context_bot_secrets_abort "missing or invalid required custom field: $context_bot_secret_name"
		# shellcheck disable=SC2317
		return 1 2>/dev/null || exit 1
	fi

	case "$context_bot_secret_name" in
	FLY_API_TOKEN)
		context_bot_fly_api_token="$context_bot_secret_value"
		;;
	SECRET_KEY_BASE)
		context_bot_secret_key_base="$context_bot_secret_value"
		;;
	BOT_APP_PASSWORD)
		context_bot_bot_app_password="$context_bot_secret_value"
		;;
	ANTHROPIC_API_KEY)
		context_bot_anthropic_api_key="$context_bot_secret_value"
		;;
	esac
done

printf -v FLY_API_TOKEN '%s' "$context_bot_fly_api_token"
printf -v SECRET_KEY_BASE '%s' "$context_bot_secret_key_base"
printf -v BOT_APP_PASSWORD '%s' "$context_bot_bot_app_password"
printf -v ANTHROPIC_API_KEY '%s' "$context_bot_anthropic_api_key"
export FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY

context_bot_secrets_cleanup
context_bot_secrets_restore_xtrace

printf 'secrets: loaded FLY_API_TOKEN\n'
printf 'secrets: loaded SECRET_KEY_BASE\n'
printf 'secrets: loaded BOT_APP_PASSWORD\n'
printf 'secrets: loaded ANTHROPIC_API_KEY\n'
