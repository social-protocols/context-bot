# Fail closed on Anthropic code-execution failures

**Date:** 2026-08-27
**TL;DR:** When dated `web_search`/`web_fetch` are enabled, Claude may call `web_search()` from
inside auto-provisioned code execution. Pairing those outer `code_execution` /
`bash_code_execution` blocks is protocol; a failed runtime result (`return_code != 0`,
documented `*_tool_result_error`, or timeout) is a terminal `provider_response` and must not
compact, split, or publish.

## Context

Live invocation 6 (2026-08-27) asked why Context Bot called the Lake America EO satire. The
retained envelope had 10 `code_execution` blocks and no native `web_search`/`web_fetch`
`server_tool_use` blocks. Usage still reported `web_search_requests: 2`. Claude had called
`web_search(...)` from the interpreter. Later Lake Ontario / Lake America queries returned
encrypted stdout with `return_code=1`. Zero `web_fetch`. The parser treated that as a
successful tool result, then published a compact reply that "reads as satire".

## Why in-sandbox search happens

Anthropic's current web tools (`web_search_20260209` / `web_fetch_20260209` and later)
auto-provision code execution for dynamic filtering. They also support programmatic tool
calling from that interpreter. Context Bot omits `allowed_callers: ["direct"]` so filtering
can run. The model can therefore invoke `web_search()` inside a cell instead of emitting a
top-level `server_tool_use` named `web_search`. Nested search/fetch with
`response_inclusion: excluded` is invisible as outer blocks; only the code-execution pair
remains. A later cell can fail with encrypted stdout and `return_code=1` while the model still
writes a compact reply.

Official behavior:

- <https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool>
- `return_code`: 0 for success, non-zero for failure
- `*_tool_result_error` with `error_code` `unavailable`, `execution_time_exceeded`,
  `invalid_tool_input`, `too_many_requests`, or `output_file_too_large`
- A 90-second programmatic cell limit returns a normal result with non-zero `return_code` and
  a `detection_timeout` status message

## Implications

- Keep pairing `code_execution` / `bash_code_execution` / `text_editor_code_execution` so a
  successful envelope is not terminalized as `unexpected_tool_use`.
- Hard-fail `Reply.select/2` and saved-turn validation on failed runtime results. Do not
  continue to compact, split, or Bluesky publish. Map the runner error
  `:code_execution_failed` to `failure_category: provider_response`.
- Do not hard-fail `return_code=0` with real stdout that merely reports a negative finding.
- Do not disable code execution: success and failure are distinguishable from the documented
  result fields.
- Prefer native `web_search` / `web_fetch` in the system prompt. Do not add undeclared tools,
  `allowed_callers`, `tool_search`, advisor, or MCP.
- Leave unknown `server_tool_use` fail-closed as `:unexpected_tool_use`.
