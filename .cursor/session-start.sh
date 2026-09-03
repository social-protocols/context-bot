#!/usr/bin/env bash
# Canonical: /home/box/deliberati/ops/session-start.sh
# Copy to each shipping repo as .cursor/session-start.sh and set
# environment.json "start" to that path. Cursor runs start on every
# Cloud Agent boot (detached). The agent should not have to fetch/pull.
set -u
if [[ -d .githooks ]]; then
  git config core.hooksPath .githooks
fi

git fetch origin --prune || {
  echo "WARN: git fetch origin failed" >&2
  exit 0
}

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

if [[ "$branch" == "main" ]]; then
  # Fast-forward pull. Never a merge commit.
  git merge --ff-only origin/main || echo "WARN: could not ff-only main to origin/main" >&2
elif [[ "$branch" != "HEAD" ]]; then
  if ! git rebase origin/main; then
    git rebase --abort >/dev/null 2>&1 || true
    echo "WARN: rebase onto origin/main failed; left $branch as fetched" >&2
  fi
elif git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  git checkout -B main origin/main || echo "WARN: could not move detached HEAD to origin/main" >&2
fi
exit 0
