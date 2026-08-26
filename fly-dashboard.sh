#!/usr/bin/env bash
set -euo pipefail

# 6PN operator dashboard. Bound in production to fly-local-6pn on INTERNAL_PORT.
# From other Fly machines: http://context-bot-social-protocols.internal:4001/invocations
# From a laptop this script uses `fly proxy`, then opens Google Chrome at the local URL.

APP="context-bot-social-protocols"
INTERNAL_HOST="${APP}.internal"
INTERNAL_PORT="4001"
LOCAL_PORT="4001"
DASHBOARD_PATH="/invocations"
LOCAL_URL="http://127.0.0.1:${LOCAL_PORT}${DASHBOARD_PATH}"

open_chrome() {
	local url="$1"

	case "$(uname -s)" in
	Darwin)
		open -a "Google Chrome" "$url"
		;;
	Linux)
		if command -v google-chrome >/dev/null 2>&1; then
			google-chrome "$url" >/dev/null 2>&1 &
		elif command -v google-chrome-stable >/dev/null 2>&1; then
			google-chrome-stable "$url" >/dev/null 2>&1 &
		else
			printf 'Error: Google Chrome not found (tried google-chrome and google-chrome-stable).\n' >&2
			exit 1
		fi
		;;
	*)
		printf 'Error: unsupported OS %s; Google Chrome launch supports macOS and Linux.\n' "$(uname -s)" >&2
		exit 1
		;;
	esac
}

if ! command -v fly >/dev/null 2>&1; then
	printf 'Error: fly CLI not found. Install flyctl and authenticate before opening the dashboard.\n' >&2
	exit 1
fi

if ! fly status -a "$APP" 2>/dev/null | grep -q "started"; then
	printf 'Fly machine is not running. Starting it...\n' >&2
	fly machine start -a "$APP"
	sleep 3
fi

proxy_pid=""

cleanup() {
	if [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
		kill "$proxy_pid" 2>/dev/null || true
		wait "$proxy_pid" 2>/dev/null || true
	fi
}

trap cleanup EXIT INT TERM

# Proxy the 6PN listener to loopback. The dashboard is not on public 80/443.
fly proxy "${LOCAL_PORT}:${INTERNAL_PORT}" "$INTERNAL_HOST" -a "$APP" &
proxy_pid=$!

sleep 1

if ! kill -0 "$proxy_pid" 2>/dev/null; then
	wait "$proxy_pid" || true
	printf 'Error: fly proxy exited before the dashboard could be opened.\n' >&2
	exit 1
fi

printf 'Proxying 6PN dashboard %s:%s%s -> %s\n' "$INTERNAL_HOST" "$INTERNAL_PORT" "$DASHBOARD_PATH" "$LOCAL_URL"
printf 'Stop with Ctrl-C.\n'
open_chrome "$LOCAL_URL"

wait "$proxy_pid"
