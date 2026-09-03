#!/usr/bin/env bash
# Canonical: /home/box/deliberati/ops/session-start.sh
# Copy to each shipping repo as .cursor/session-start.sh and set
# environment.json "start" to that path. Cursor runs start on every
# Cloud Agent boot (detached). Do not rebase here.
set -u
if [[ -d .githooks ]]; then
  git config core.hooksPath .githooks
fi
git fetch origin --prune || echo "WARN: git fetch origin failed" >&2
exit 0
