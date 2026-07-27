#!/usr/bin/env bash

context_bot_secrets_fail() {
	printf 'secrets: %s\n' "$1" >&2
	return 1
}

if [[ -z "${BITWARDEN_ITEM_ID:-}" ]]; then
	context_bot_secrets_fail "BITWARDEN_ITEM_ID is required"
	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return 1
	else
		exit 1
	fi
fi

if ! context_bot_bitwarden_item="$(bw get item "$BITWARDEN_ITEM_ID")"; then
	context_bot_secrets_fail "unable to read Bitwarden item; log in and unlock the vault"
	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return 1
	else
		exit 1
	fi
fi

for context_bot_secret_name in FLY_API_TOKEN SECRET_KEY_BASE; do
	if ! context_bot_secret_value="$(
		jq -er --arg name "$context_bot_secret_name" \
			'[.fields[]? | select(.name == $name) | .value][0] // empty' \
			<<<"$context_bot_bitwarden_item"
	)"; then
		context_bot_secrets_fail "missing required custom field: $context_bot_secret_name"
		if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
			return 1
		else
			exit 1
		fi
	fi

	printf -v "$context_bot_secret_name" '%s' "$context_bot_secret_value"
	export "${context_bot_secret_name?}"
	printf 'secrets: loaded %s\n' "$context_bot_secret_name"
done

unset context_bot_bitwarden_item context_bot_secret_name context_bot_secret_value
unset -f context_bot_secrets_fail
