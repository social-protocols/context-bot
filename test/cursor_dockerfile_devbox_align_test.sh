#!/usr/bin/env bash
# Cheap drift check: .cursor/Dockerfile must mention each non-Beam package
# name from devbox.json. Beam packages are the hexpm Elixir/OTP base image.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
devbox="$project_root/devbox.json"
dockerfile="$project_root/.cursor/Dockerfile"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[[ -f "$devbox" ]] || fail "devbox.json is missing"
[[ -f "$dockerfile" ]] || fail ".cursor/Dockerfile is missing"

grep -qE '^FROM hexpm/elixir:' "$dockerfile" ||
	fail ".cursor/Dockerfile must keep the hexpm Elixir/OTP base image"

if grep -qE 'apt-get install[^\n]*\b(elixir|erlang)\b' "$dockerfile"; then
	fail ".cursor/Dockerfile must not apt-get install a second Elixir/Erlang"
fi

# Non-Beam Devbox packages are pinned as "name": "latest" (or another string).
# Flake Beam keys and nested objects are skipped.
missing=()
while IFS= read -r name; do
	[[ -n "$name" ]] || continue
	if ! grep -qF "$name" "$dockerfile"; then
		missing+=("$name")
	fi
done < <(sed -nE 's/^[[:space:]]*"([a-z0-9-]+)":[[:space:]]*"[^"]+".*/\1/p' "$devbox")

if ((${#missing[@]} > 0)); then
	fail "Dockerfile does not mention non-Beam devbox.json packages: ${missing[*]}"
fi

printf 'cursor Dockerfile mentions every non-Beam devbox.json package\n'
