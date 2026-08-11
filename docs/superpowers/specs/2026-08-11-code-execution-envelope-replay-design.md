# Code-execution envelope replay design

## Problem

Anthropic's dated web tools may use automatically provisioned code execution for dynamic
filtering. A successful response can therefore contain paired `server_tool_use` blocks named
`code_execution` and `code_execution_tool_result` blocks even though Context Bot configured only
web search and web fetch. Context Bot currently rejects that documented response shape as
`unexpected_tool_use` after paying for and durably storing the completed response.

Terminal invocations are intentionally excluded from automatic interruption recovery. That is
correct for ambiguous or genuine provider failures, but there is no guarded operator path to
reprocess a complete retained response after correcting a local decoder or validator bug.

## Response validation

Keep dynamic filtering and `response_inclusion: "excluded"`. Extend reply selection to accept
`code_execution` only as an Anthropic server tool. Every call must have a nonempty string ID, an
input map, and exactly one matching `code_execution_tool_result`. The result must have a nonempty
matching `tool_use_id` and a map-valued `content`; the nested provider payload remains opaque for
forward compatibility. Orphaned, duplicate, malformed, client-side, and unknown tool blocks
continue to fail closed.

Code-execution contents never contribute to the Bluesky reply. Only model-authored `text` blocks
are concatenated and validated. Code-execution calls do not count against the direct web-search or
web-fetch use caps; Anthropic's usage object remains the source of billing evidence.

Pause-turn continuation tracks `code_execution` calls with the same pairing rules as the existing
server tools so a result returned at the start of a continuation can close a prior call.

## Guarded reprocessing

Add an explicit workflow operation and Mix task for reprocessing one invocation by integer ID. It
may reopen an invocation only when all of the following are true:

- status and stage are both `failed`;
- failure category is `provider_response`;
- a latest budget attempt exists and has a durably recorded response envelope;
- there is no exposed attempt without a recorded envelope;
- the recorded envelope has a 2xx HTTP status and a JSON object body; and
- the invocation still has a canonical thread and its saved Anthropic request.

The reopening transition and insertion of a new research job occur in one immediate SQLite
transaction. It clears terminal and claim fields, returns the invocation to `thread_ready`, and
uses the dry or public research queue according to `dry_run`. Repeated or concurrent requests
after the first transition fail safely and cannot enqueue duplicate work.

The research runner then finds the latest recorded attempt and processes its stored envelope
without another research POST. If its model-authored reply is too long, the existing bounded
length-repair path may reserve and send one repair request. The daily budget applies normally.

Expose this as `mix context_bot.reprocess INVOCATION_ID` and `just reprocess INVOCATION_ID`. The
command requires `BOT_ENABLED=false` and fails if local Context Bot workers are already running. It
starts only the database dependencies, never the full application, then performs the guarded state
transition and prints the reopened invocation ID. Public-invocation reprocessing therefore requires
a bot-disabled maintenance window. A subsequent normal `just dry-run ...` invocation attaches to
and processes the reopened dry run, preserving the existing progress and interruption behavior.

## Verification

Behavior-first tests cover the live code-execution block shape, malformed and mismatched pairs,
pause-turn tracking, all reprocessing guards, atomic job insertion, queue selection, concurrency,
and Mix task output. A runner regression proves a retained envelope is processed without invoking
the Anthropic client. Invocation 3 is reopened only after the complete suite passes; its stored
research response is preserved, and any new spend is limited to the required length repair.
