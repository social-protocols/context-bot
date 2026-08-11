# Anthropic dynamic-filtering code execution and retained replay

**Date:** 2026-08-11
**TL;DR:** Anthropic's current web tools can automatically emit outer code-execution call/result
pairs under dynamic filtering. Treat those pairs as server-tool protocol, and reprocess a complete
stored envelope after local parser failures instead of repeating paid research.

## Context

Dry-run invocation 3 paid for and stored a successful Claude Sonnet 5 response, then Context Bot
marked it `provider_response/unexpected_tool_use`. The API dashboard showed multiple same-request-ID
rows and the SQLite budget ledger settled the research attempt at 102,223 microdollars.

## Investigation

The retained envelope was valid JSON with HTTP 200 and `stop_reason: end_turn`. Its content order
contained thinking blocks, six paired `server_tool_use` blocks named `code_execution` and
`code_execution_tool_result` blocks, then three model-authored text blocks. The reply parser allowed
only `web_search` and `web_fetch`, so it rejected the first code-execution call before reaching the
completed text.

Anthropic's official web-search documentation explains that `web_search_20260209` and later can run
dynamic filtering inside automatically provisioned code execution. The client does not add a code
execution tool itself. `response_inclusion: "excluded"` removes nested web-search call/result pairs
consumed inside that execution, but the outer code-execution result blocks remain:

- <https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/web-search-tool>
- <https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/code-execution-tool>

The stored model text was 337 Unicode code points and 349 UTF-8 bytes, so accepting the envelope
still leads to the existing bounded length-repair call. The expensive research call does not need
to be repeated.

## Findings

- A configured web-only request does not imply a web-only response block vocabulary when dynamic
  filtering is enabled.
- Excluded response inclusion and code-execution response blocks are compatible: exclusion applies
  to nested search/fetch material, not necessarily the enclosing execution pair.
- Code-execution output must never be concatenated into the Bluesky reply; only model-authored text
  blocks are candidates.
- A complete retained envelope is sufficient to resume Runner decoding, settlement, selection, and
  repair without another research POST.
- Pairing validation must retain every previously seen server-tool ID across saved assistant turns;
  tracking only currently pending calls permits a completed ID to be reused later.
- Automatic orphan recovery should continue to ignore terminal failures. Reopening a terminal row
  requires an explicit, guarded operator action because genuine and ambiguous provider failures
  must remain terminal.
- A Mix maintenance task must not start the full application merely to access SQLite: that can
  start Oban, polling, and authenticated ATProto processes before its guard runs. Start only Ecto's
  SQLite dependencies and the Repo, require `BOT_ENABLED=false`, and reject an already active local
  worker runtime.

## Implications

Validate nonempty IDs and one-to-one pairing for documented server-tool calls/results while keeping
nested code-execution content opaque. Track code-execution pairs across `pause_turn`, but do not add
them to direct web-search/fetch caps. Before reopening a failed invocation, require a provider
response failure, saved request/thread, no unrecorded exposure, and a 2xx JSON-object envelope for
the latest attempt. Perform the state transition and research-job insertion atomically.
Give the replay job a fresh nonce so a still-`executing` historical Oban job cannot suppress the
new durable work through uniqueness. Keep the invocation transition as the concurrency guard.
