#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

cd "$project_root"

# Test fly-reprocess recipe exists and takes an invocation_id
context_bot_test_tmp="$(mktemp -d)"
export CONTEXT_BOT_TEST_TMP="$context_bot_test_tmp"

trap 'rm -rf "$context_bot_test_tmp"' EXIT

if ! just --summary 2>/dev/null | grep -qw "fly-reprocess"; then
	fail "fly-reprocess recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-invocation"; then
	fail "fly-invocation recipe not found in justfile"
fi

# Verify fly-reprocess recipe structure (without actually executing SSH)
recipe_content=$(just --show fly-reprocess 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly ssh console"* ]] || fail "fly-reprocess does not use fly ssh console"
	[[ "$recipe_content" == *"context-bot-social-protocols"* ]] || fail "fly-reprocess does not target correct app"
	[[ "$recipe_content" == *"/app/bin/context_bot"* ]] || fail "fly-reprocess does not use context_bot eval"
	[[ "$recipe_content" == *"ContextBot.Repo.start_link"* ]] || fail "fly-reprocess does not start Repo"
	[[ "$recipe_content" == *"Reprocessor.reprocess"* ]] || fail "fly-reprocess does not call Reprocessor"
fi

# Verify fly-invocation recipe structure
recipe_content=$(just --show fly-invocation 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly ssh console"* ]] || fail "fly-invocation does not use fly ssh console"
	[[ "$recipe_content" == *"sqlite3 -json"* ]] || fail "fly-invocation does not use sqlite3 -json"
	[[ "$recipe_content" == *"/data/context_bot.db"* ]] || fail "fly-invocation does not query production database"
	[[ "$recipe_content" == *"jq"* ]] || fail "fly-invocation does not use jq"
	[[ "$recipe_content" == *"fromjson"* ]] || fail "fly-invocation does not parse failure_detail JSON"
fi

printf 'fly wrapper tests passed\n'
