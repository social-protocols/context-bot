# Task 5 Report — Direct-Mention Polling and Idempotent Receipt

## RED

- Validator tests failed because `ContextBot.Mentions.Validator.validate/2` did not exist.
- The durable watermark test failed because `ContextBot.Workflow.Store.received?/2` did not exist.
- Poller tests failed because `ContextBot.Mentions.Poller` did not exist.

## GREEN

- Added strict facet-based direct-mention validation that preserves the raw notification.
- Added durable `(URI, CID)` receipt lookup and a non-overlapping, newest-first poller.
- The poller follows opaque cursors through empty pages, stops at a known durable receipt or page cap, stores discoveries oldest-first, and defers receipt admission when capacity is unavailable.
- Future eligibility jobs use `Oban.Job.new/2` with the worker name string; no Task 6 module or eligibility logic is compiled.
- Enabled bots now supervise the poller after the ATProto session.

## Gate

- Focused: `direnv exec . mix test test/context_bot/mentions/validator_test.exs test/context_bot/mentions/poller_test.exs test/context_bot/workflow/store_test.exs test/context_bot/application_test.exs` — 30 passed.
- Full: `direnv exec . just check` — formatting, warnings-as-errors compile, Credo, ShellCheck, 87 ExUnit tests, secrets tests, and Dialyzer passed.

## Commit

- `feat: ingest direct Bluesky mentions`

## Concerns

- None. The backward pagination cursor is deliberately process-local and is never persisted as a forward checkpoint; receipt admission remains backpressure only, with Task 6 responsible for transactional rechecks.
