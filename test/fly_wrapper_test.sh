#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

cd "$project_root"

context_bot_test_tmp="$(mktemp -d)"
export CONTEXT_BOT_TEST_TMP="$context_bot_test_tmp"

cleanup() {
	if [[ -n "${dashboard_pid:-}" ]] && kill -0 "$dashboard_pid" 2>/dev/null; then
		kill "$dashboard_pid" 2>/dev/null || true
		wait "$dashboard_pid" 2>/dev/null || true
	fi
	rm -rf "$context_bot_test_tmp"
}
trap cleanup EXIT

if ! just --summary 2>/dev/null | grep -qw "fly-reprocess"; then
	fail "fly-reprocess recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-invocation"; then
	fail "fly-invocation recipe not found in justfile"
fi

if ! just --summary 2>/dev/null | grep -qw "fly-dashboard"; then
	fail "fly-dashboard recipe not found in justfile"
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

# Verify fly-dashboard recipe structure
recipe_content=$(just --show fly-dashboard 2>/dev/null || echo "")
if [[ -n "$recipe_content" ]]; then
	[[ "$recipe_content" == *"fly-dashboard.sh"* ]] || fail "fly-dashboard does not call fly-dashboard.sh"
fi

[[ -x "$project_root/fly-dashboard.sh" ]] || fail "fly-dashboard.sh is not executable"

dashboard_script=$(cat "$project_root/fly-dashboard.sh")
[[ "$dashboard_script" == *"fly proxy"* ]] || fail "fly-dashboard.sh does not use fly proxy"
[[ "$dashboard_script" == *"context-bot-social-protocols.internal"* ]] || fail "fly-dashboard.sh does not target the 6PN hostname"
[[ "$dashboard_script" == *"4001"* ]] || fail "fly-dashboard.sh does not use internal port 4001"
[[ "$dashboard_script" == *"/invocations"* ]] || fail "fly-dashboard.sh does not open /invocations"
[[ "$dashboard_script" == *'open -a "Google Chrome"'* ]] || fail "fly-dashboard.sh does not open Google Chrome on macOS"
[[ "$dashboard_script" == *"google-chrome-stable"* ]] || fail "fly-dashboard.sh does not fall back to google-chrome-stable on Linux"
[[ "$dashboard_script" != *"xdg-open"* ]] || fail "fly-dashboard.sh must open Chrome, not xdg-open"
[[ "$dashboard_script" == *'APP="context-bot-social-protocols"'* ]] || fail "fly-dashboard.sh does not set the Fly app name"

wait_for_file() {
	local path="$1"
	local _attempt
	for _attempt in {1..40}; do
		[[ -f "$path" ]] && return 0
		sleep 0.05
	done
	return 1
}

run_dashboard_with_fakes() {
	local fake_bin="$context_bot_test_tmp/bin"
	mkdir -p "$fake_bin"
	rm -f "$context_bot_test_tmp/fly-commands" "$context_bot_test_tmp/chrome-url"

	cat >"$fake_bin/fly" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CONTEXT_BOT_TEST_TMP}/fly-commands"
if [[ "${1:-}" == "status" ]]; then
	printf 'started\n'
	exit 0
fi
if [[ "${1:-}" == "proxy" ]]; then
	while true; do
		sleep 0.1
	done
fi
exit 0
EOF

	cat >"$fake_bin/google-chrome" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${CONTEXT_BOT_TEST_TMP}/chrome-url"
exit 0
EOF

	chmod +x "$fake_bin/fly" "$fake_bin/google-chrome"

	PATH="$fake_bin:$PATH" "$project_root/fly-dashboard.sh" \
		>"$context_bot_test_tmp/dashboard-output" 2>&1 &
	dashboard_pid=$!

	if ! wait_for_file "$context_bot_test_tmp/chrome-url"; then
		if [[ -f "$context_bot_test_tmp/dashboard-output" ]]; then
			cat "$context_bot_test_tmp/dashboard-output" >&2
		fi
		fail "fly-dashboard.sh did not launch Chrome"
	fi

	fly_commands=$(cat "$context_bot_test_tmp/fly-commands")
	[[ "$fly_commands" == *"proxy 4001:4001 context-bot-social-protocols.internal -a context-bot-social-protocols"* ]] ||
		fail "fly proxy was not invoked with the 6PN host and internal port"

	chrome_url=$(cat "$context_bot_test_tmp/chrome-url")
	[[ "$chrome_url" == "http://127.0.0.1:4001/invocations" ]] ||
		fail "Chrome was not opened at the proxied dashboard URL (got: $chrome_url)"

	kill "$dashboard_pid" 2>/dev/null || true
	wait "$dashboard_pid" 2>/dev/null || true
	dashboard_pid=""
}

run_dashboard_with_fakes

fly_toml=$(cat "$project_root/fly.toml")
[[ "$fly_toml" == *'kill_signal = "SIGTERM"'* ]] || fail "fly.toml does not set kill_signal SIGTERM"
[[ "$fly_toml" == *"kill_timeout = 300"* ]] || fail "fly.toml does not set kill_timeout 300"

server_script=$(cat "$project_root/rel/overlays/bin/server")
[[ "$server_script" == *"forward_term"* ]] || fail "release server does not forward shutdown signals"
[[ "$server_script" == *"INT TERM"* ]] || fail "release server does not trap INT and TERM"
[[ "$server_script" == *"+B i"* ]] || fail "release server does not ignore the Erlang BREAK menu"
[[ "$server_script" == *"kill -TERM"* ]] || fail "release server does not forward SIGTERM to the BEAM"

printf 'fly wrapper tests passed\n'
