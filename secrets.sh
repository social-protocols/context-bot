#!/usr/bin/env bash

context_bot_secrets_fail() {
	printf 'secrets: %s\n' "$1" >&2
	return 1
}

context_bot_secrets_cleanup() {
	unset context_bot_bitwarden_item context_bot_secret_name context_bot_secret_value
	unset context_bot_fly_api_token context_bot_secret_key_base
	unset context_bot_bot_app_password context_bot_anthropic_api_key
	unset -f context_bot_secrets_fail context_bot_secrets_cleanup
}

if [[ -z "${BITWARDEN_ITEM_ID:-}" ]]; then
	context_bot_secrets_fail "BITWARDEN_ITEM_ID is required"
	context_bot_secrets_cleanup
	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return 1
	else
		exit 1
	fi
fi

if ! context_bot_bitwarden_item="$(bw get item "$BITWARDEN_ITEM_ID")"; then
	context_bot_secrets_fail "unable to read Bitwarden item; log in and unlock the vault"
	context_bot_secrets_cleanup
	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return 1
	else
		exit 1
	fi
fi

for context_bot_secret_name in FLY_API_TOKEN SECRET_KEY_BASE BOT_APP_PASSWORD ANTHROPIC_API_KEY; do
	if ! context_bot_secret_value="$(
		jq -er --arg name "$context_bot_secret_name" \
			'[.fields[]? | select(.name == $name) | .value][0] // empty' \
			<<<"$context_bot_bitwarden_item"
	)"; then
		context_bot_secrets_fail "missing required custom field: $context_bot_secret_name"
		context_bot_secrets_cleanup
		if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
			return 1
		else
			exit 1
		fi
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
printf 'secrets: loaded FLY_API_TOKEN\n'
printf 'secrets: loaded SECRET_KEY_BASE\n'
printf 'secrets: loaded BOT_APP_PASSWORD\n'
printf 'secrets: loaded ANTHROPIC_API_KEY\n'

context_bot_secrets_cleanup
