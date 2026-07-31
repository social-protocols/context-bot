# Task 10 Report: Cached Claude Conversations and Reply Selection

## Outcome

Implemented pure Anthropic Messages request construction and reply selection. Initial requests use
the pinned Sonnet 5 adaptive-thinking and dated direct web-tool contract. Continuations and length
repairs preserve the complete conversation opaquely and append-only. Reply selection never
truncates model text and fails closed on incomplete, refusal, tool, unknown, and malformed states.

Commit message: `feat: construct cached Claude conversations`

## TDD evidence

### RED

Focused tests were introduced before each production behavior and failed for the intended reason:

- the initial request, continuation, repair, and reply modules/functions were initially undefined;
- the placeholder system prompt lacked the required research and safety instructions;
- a mismatched continuation token limit raised an unspecified function-clause error rather than
  enforcing the cache invariant explicitly;
- persisted string-key canonical thread maps were not accepted;
- completed server-tool pairs were initially rejected;
- over-limit normal completions returned a terminal error rather than intact repairable text;
- whitespace-only output was accepted;
- refusal/incomplete stop reasons raised rather than returning terminal classifications;
- client, pending, orphaned, refusal, unknown, and malformed blocks lacked fail-closed reasons;
- review-driven regression tests proved matching search/fetch result blocks without a documented
  `content` payload could incorrectly allow text publication.

### GREEN

Final focused command:

```text
direnv exec . mix test test/context_bot/research/request_test.exs test/context_bot/research/reply_test.exs
```

Result: `14 passed`, exit 0.

Coverage includes exact request fields and tool definitions, absence of sampling/display fields,
the complete versioned prompt contract, string-key persistence input, opaque continuation and
repair blocks, append-only cache prefixes, exact Unicode/byte boundaries, ordered text
concatenation, completed tool pairs, no truncation, and terminal malformed/provider states.

## Review

An independent read-only review found no Critical issues and one Important fail-open edge for
server-tool result blocks missing their documented outer `content` shape. The fix requires a
nonempty tool-use ID plus list-or-map `content`, keeps the payload opaque, and returns a terminal
error for missing or malformed payloads. The focused suite passed after the fix.

## Full gate

The first `direnv exec . just check` reached Credo and failed only because `Reply.select/2` nested
classification control flow one level beyond the project limit. Extracting pure text/limit
classification helpers removed that structural issue without changing behavior; targeted Credo
and the focused suite then passed.

Fresh final command:

```text
direnv exec . just check
```

Result: exit 0.

- format and Shell formatting checks passed;
- compilation with warnings as errors passed;
- Credo strict and ShellCheck found no issues;
- ExUnit: `199 passed`, 0 failures;
- secrets shell tests passed;
- Dialyzer: 0 errors, 0 skipped, 0 unnecessary skips.

## Files changed

- `lib/context_bot/research/request.ex`
- `lib/context_bot/research/reply.ex`
- `test/context_bot/research/request_test.exs`
- `test/context_bot/research/reply_test.exs`
- `.superpowers/sdd/2026-07-29-context-bot-poc/task-10-report.md`

## Concerns

- No open blockers. Tool versions are deliberately fixed to the brief's dated contract; model and
  token/search/fetch caps are explicit caller-supplied configuration.
- Known search/fetch result payloads are validated only at the documented outer shape and remain
  opaque, preserving forward-compatible provider fields while preventing malformed completion.
