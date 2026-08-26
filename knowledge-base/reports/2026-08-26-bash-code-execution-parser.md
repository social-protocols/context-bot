# Anthropic bash/text-editor code-execution sub-tools

**Date:** 2026-08-26
**TL;DR:** Current Anthropic web tools can emit `bash_code_execution` and
`text_editor_code_execution` pairs in addition to Python `code_execution`. Treat those
pairs as server-tool protocol so a completed `end_turn` envelope is not terminalized as
`unexpected_tool_use`.

## Context

Production invocation 3 (`at://did:plc:33avz2l7y5scw3abq3lmylns/app.bsky.feed.post/3mtxfarxazk2a`)
paid for and stored an HTTP 200 Claude Sonnet 5 response (`stop_reason: end_turn`), then
Context Bot marked it `provider_response/unexpected_tool_use`. The envelope contained 13
paired `code_execution` blocks, then one `bash_code_execution` / `bash_code_execution_tool_result`
pair (`command: sleep 20 && echo done`), then more code execution and a complete model text
block with `---COMPACT_REPLY---`.

The 2026-08-11 parser update allowed only `code_execution`. Anthropic's current code-execution
tool versions document bash and text-editor sub-tools:

- <https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool>

## Findings

- Nested web search/fetch with `response_inclusion: excluded` still bills
  `usage.server_tool_use` while remaining invisible as top-level `server_tool_use` blocks.
- Outer `bash_code_execution` pairs are not nested search results; they are first-class
  content blocks and must be paired like `code_execution`.
- Bash/text-editor stdout must never be concatenated into the Bluesky reply.
- A complete retained envelope is sufficient to resume decode after the parser change;
  do not issue another research POST for this failure class.

## Implications

Keep fail-closed on client `tool_use` and unknown server-tool names. Do not count bash or
text-editor pairs against web-search/fetch caps. After deploying the parser, invocation 3 is
a candidate for explicit envelope replay.
