#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

cd "$project_root"

if ! just --summary 2>/dev/null | grep -qw "fly-reprocess"; then
	fail "fly-reprocess recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-reenqueue"; then
	fail "fly-reenqueue recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-invocation"; then
	fail "fly-invocation recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-recover"; then
	fail "fly-recover recipe not found in justfile"
fi

if just --summary 2>/dev/null | grep -qw "fly-dashboard"; then
	fail "fly-dashboard recipe should be removed; invocations are public on GET /invocations"
fi

[[ ! -e "$project_root/fly-dashboard.sh" ]] || fail "fly-dashboard.sh should be removed"

# Verify fly-reprocess recipe structure (without actually executing SSH)
recipe_content=$(just --show fly-reprocess 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly ssh console"* ]] || fail "fly-reprocess does not use fly ssh console"
	[[ "$recipe_content" == *"context-bot-social-protocols"* ]] || fail "fly-reprocess does not target correct app"
	[[ "$recipe_content" == *"/app/bin/context_bot"* ]] || fail "fly-reprocess does not use context_bot eval"
	[[ "$recipe_content" == *"ContextBot.Repo.start_link"* ]] || fail "fly-reprocess does not start Repo"
	[[ "$recipe_content" == *"Reprocessor.reprocess"* ]] || fail "fly-reprocess does not call Reprocessor"
fi

# Verify fly-reenqueue recipe structure (without actually executing SSH)
recipe_content=$(just --show fly-reenqueue 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly ssh console"* ]] || fail "fly-reenqueue does not use fly ssh console"
	[[ "$recipe_content" == *"context-bot-social-protocols"* ]] || fail "fly-reenqueue does not target correct app"
	[[ "$recipe_content" == *"/app/bin/context_bot"* ]] || fail "fly-reenqueue does not use context_bot eval"
	[[ "$recipe_content" == *"ContextBot.Repo.start_link"* ]] || fail "fly-reenqueue does not start Repo"
	[[ "$recipe_content" == *"Reenqueuer.reenqueue"* ]] || fail "fly-reenqueue does not call Reenqueuer"
	[[ "$recipe_content" != *"Reprocessor.reprocess"* ]] || fail "fly-reenqueue must not call Reprocessor.reprocess"
fi

# Verify fly-recover recipe structure (without actually executing SSH)
recipe_content=$(just --show fly-recover 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly ssh console"* ]] || fail "fly-recover does not use fly ssh console"
	[[ "$recipe_content" == *"context-bot-social-protocols"* ]] || fail "fly-recover does not target correct app"
	[[ "$recipe_content" == *"/app/bin/context_bot"* ]] || fail "fly-recover does not use context_bot eval"
	[[ "$recipe_content" == *"ContextBot.Repo.start_link"* ]] || fail "fly-recover does not start Repo"
	[[ "$recipe_content" == *"Recovery.recover_orphans"* ]] || fail "fly-recover does not call Recovery.recover_orphans"
	[[ "$recipe_content" == *"Recovery.recover_invocation"* ]] || fail "fly-recover does not call Recovery.recover_invocation"
	[[ "$recipe_content" == *"operator?: true"* ]] || fail "fly-recover one-id path does not pass operator?: true"
	[[ "$recipe_content" == *"job_states"* ]] || fail "fly-recover does not pass live-app job-state options"
	[[ "$recipe_content" != *"Reprocessor.reprocess"* ]] || fail "fly-recover must not call Reprocessor.reprocess"
	[[ "$recipe_content" != *"Reenqueuer.reenqueue"* ]] || fail "fly-recover must not call Reenqueuer.reenqueue"
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

fly_toml=$(cat "$project_root/fly.toml")
[[ "$fly_toml" == *'kill_signal = "SIGTERM"'* ]] || fail "fly.toml does not set kill_signal SIGTERM"
[[ "$fly_toml" == *"kill_timeout = 300"* ]] || fail "fly.toml does not set kill_timeout 300"
[[ "$fly_toml" != *"INTERNAL_PORT"* ]] || fail "fly.toml still sets INTERNAL_PORT"
[[ "$fly_toml" != *"6PN"* ]] || fail "fly.toml still mentions a 6PN-only dashboard"

server_script=$(cat "$project_root/rel/overlays/bin/server")
[[ "$server_script" == *"forward_term"* ]] || fail "release server does not forward shutdown signals"
[[ "$server_script" == *"INT TERM"* ]] || fail "release server does not trap INT and TERM"
[[ "$server_script" == *"+B i"* ]] || fail "release server does not ignore the Erlang BREAK menu"
[[ "$server_script" == *"kill -TERM"* ]] || fail "release server does not forward SIGTERM to the BEAM"

printf 'fly wrapper tests passed\n'
