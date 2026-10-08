# Cursor-only repo notes

Copy or merge into `.cursor/` in shipping repos. Do **not** put this content in root `AGENTS.md`.

## Cloud agent model

Launch with model **Grok 4.6** (`grok-4.6`). Fallback **Claude Sonnet 4.6** (`claude-sonnet-4-6`) if Grok 4.6 is unavailable. Not Opus unless Jonathan says so for that run.

Do **not** paste standing shipping rules into CloudAgent launch/reply prompts. Root `AGENTS.md` is what Cursor already reads for policy.

## Session start

`install` (Build time) may set `core.hooksPath=.githooks` and warm deps. `start` is `.cursor/session-start.sh` (from `repo-setup/templates/session-start.sh`): re-sets hooksPath if `.githooks` exists, `git fetch`es, fast-forwards trunk to `origin/<trunk>`, and rebases a feature branch onto `origin/<trunk>` (aborts on conflict). Agents should not fetch, pull, or rebase unless start failed. `start` is detached, so wait for it if `origin/<trunk>` is needed immediately. Because start rebases, a feature branch that was already pushed needs `git push --force-with-lease` afterwards; a plain push is rejected.

Optional `.cursor/trunk` file: one line, the trunk branch name (default `main` if absent). Repos with a multi-line branch model document their targets in `AGENTS.md` and may omit `.cursor/trunk`. A repo with no single trunk may ship a session-start that only fetches (no ff/rebase) when `.cursor/trunk` is absent, as long as it documents why. Do not change the template's default behaviour.

Start new work from current trunk on a new VM. Reply to the existing cloud agent for the same PR; do not launch a second one on the same branch.

## environment.json

Set `"start": ".cursor/session-start.sh"`. Create a minimal `.cursor/environment.json` if the repo has none.
