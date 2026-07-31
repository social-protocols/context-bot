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

## Fix Round 1: Continuation Results and Provider Block Shapes

### Findings addressed

- `Reply.select/2` now accepts a documented context second argument containing prior pending
  server-tool IDs and names. A continued response may begin with the matching result block, while
  mismatched, unknown, orphaned, and still-pending tools remain terminal. The bare stop-reason form
  remains supported. Prior pause text is neither accepted by the context nor concatenated into the
  selected reply.
- Known provider blocks now validate their documented outer discriminated shapes. Thinking and
  redacted-thinking fields must be strings; direct server calls require a nonempty string ID, a
  recognized name, and map input; search/fetch results recognize documented success and error
  variants. Extra provider metadata and nested document data remain opaque. `caller` stays optional
  because Anthropic's documented direct server-tool responses do not require it.

### TDD evidence

Each behavioral slice failed for its intended reason before its implementation:

- the leading post-pause result was classified as orphaned before prior pending-call context was
  supported, then the reply suite passed `9` tests;
- malformed thinking blocks plus valid text were accepted (`9/10 passed`), then passed after outer
  field/type validation;
- server calls without valid `id`, `name`, or map `input` did not consistently return malformed
  content (`10/11 passed`), then passed after call-shape validation;
- arbitrary list/map result payloads allowed trailing text to publish (`12/13 passed`), then passed
  after success/error discriminated-shape validation;
- the exact documented cross-response fetch result without optional `retrieved_at` was initially
  rejected (`14/15 passed`), then passed while malformed present values remain rejected;
- final review regressions showed that text could precede a pending continuation result and that
  opaque non-map server-tool input was overvalidated (`14/16 passed`). The selector now requires
  all prior results as a leading prefix and requires the `input` field without inspecting its
  nested value.

Fresh focused command:

```text
direnv exec . mix test test/context_bot/research/request_test.exs test/context_bot/research/reply_test.exs
```

Result: `22 passed`, exit 0.

### Review

A final independent read-only review found no Critical issues and two Important edges: continuation
results needed to form a strict leading prefix, and required server-tool `input` needed to remain
opaque. Both findings were addressed with the RED/GREEN regressions above. The formal scoped
re-review follows this fix commit.

### Full gate

Fresh command:

```text
direnv exec . just check
```

Result: exit 0.

- formatting, compilation with warnings as errors, Credo strict, and ShellCheck passed;
- ExUnit: `207 passed`, 0 failures;
- secrets shell tests passed;
- Dialyzer: 0 errors, 0 skipped, 0 unnecessary skips.

Commit message: `fix: validate Claude continuation blocks`
