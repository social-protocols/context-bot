# Context Bot Operational Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give dry runs useful progress, safe JSONL logs, interruption-safe recovery, and lower ordinary Anthropic research cost without weakening the durable budget ledger.

**Architecture:** Keep human output in a small `ContextBot.DryRun.Progress` renderer and route all OTP/application logs through an allowlisting JSON formatter. Centralize orphan classification in `ContextBot.Workflow.Recovery`, call it before Oban consumers start, and make exposed Anthropic attempts terminal whenever no response envelope exists. Preserve the existing workers and SQLite schema while changing request construction and validated settings to cheaper defaults.

**Tech Stack:** Elixir 1.20, Erlang/OTP 28, Phoenix 1.8, Ecto/SQLite, Oban 2.23, Jason, ExUnit, Devbox, Docker, Fly.io.

## Global Constraints

- Run every command through `direnv exec .`; do not use host-installed Elixir, Erlang, SQLite, or quality tools.
- Work only in `.worktrees/operational-hardening` on `codex/operational-hardening` until integration.
- Write a behavior-first failing ExUnit test before each implementation change.
- Do not make a live Anthropic call, Bluesky write, Fly deployment, or Bitwarden mutation during verification.
- Logger output must never contain notification/thread bodies, prompts, Anthropic response bodies, selected replies, credentials, authorization headers, or Bitwarden values.
- `CONTEXT_BOT_LOG_PATH` is either empty/unset (stderr) or an absolute append-only file; invalid destinations fail before external work begins.
- TTY progress is an indeterminate spinner; non-TTY progress is one plain line per durable stage; neither invents a completion percentage.
- A research attempt becomes provider-exposed when its budget entry is committed as `sent`. A `sent` attempt without a stored response envelope is terminal `provider_response/interrupted_after_send` and is never automatically retried.
- Recovery must preserve dry/public queue separation and be idempotent.
- Keep the current $5 research reservation. It is a fail-closed exposure reservation, not the charged amount.
- Default ordinary research settings become effort `medium`, output tokens `4096`, searches `2`, fetches `2`, fetched-content tokens `10000`, and continuations `1`.
- Keep Anthropic tool versions `web_search_20260318` and `web_fetch_20260318`; omit direct-caller and cache-bypass fields and use `response_inclusion: "excluded"`.
- Preserve the user's main-checkout `justfile` setting `set dotenv-load := true` if the feature branch must touch that file.
- Before completion run `direnv exec . just check`, `direnv exec . just docker-build`, and a production-image `/health` smoke test with `BOT_ENABLED=false`.

---

## File map

### New files

- `lib/context_bot/logging.ex` — validates `CONTEXT_BOT_LOG_PATH` and returns Logger handler configuration without logging the supplied environment.
- `lib/context_bot/logging/json_formatter.ex` — formats one safe JSON object per Logger event and allowlists scalar metadata.
- `lib/context_bot/dry_run/progress.ex` — owns TTY/non-TTY progress state and rendering to stdout.
- `lib/context_bot/dry_run/interrupts.ex` — installs scoped SIGINT/SIGTERM callbacks and turns them into a foreground cancellation message.
- `lib/context_bot/workflow/recovery.ex` — classifies orphaned jobs and applies the common durable recovery matrix.
- `lib/context_bot/workflow/startup_recovery.ex` — synchronous, idle-after-init supervisor child that runs recovery before Oban.
- `test/context_bot/logging_test.exs` and `test/context_bot/logging/json_formatter_test.exs` — destination and redaction behavior.
- `test/context_bot/dry_run/progress_test.exs` and `test/context_bot/dry_run/interrupts_test.exs` — deterministic terminal and signal behavior.
- `test/context_bot/workflow/recovery_test.exs` and `test/context_bot/workflow/startup_recovery_test.exs` — recovery matrix, idempotence, and ordering.

### Existing files changed

- `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs` — global JSON logging, disabled SQL query logging, and runtime destination validation.
- `lib/context_bot/operations.ex` — emit the existing attempt event as Logger metadata rather than embedded JSON text.
- `lib/context_bot/dry_run.ex` — stage-change callback and interrupt-aware wait loop.
- `lib/mix/tasks/context_bot.dry_run.ex` — progress lifecycle, early invocation ID, and clean interruption result.
- `lib/context_bot/dry_run/runtime.ex` — shared startup recovery before dry queues start.
- `lib/context_bot/settings.ex` — validated effort and cheaper ordinary defaults.
- `lib/context_bot/research/request.ex` — lower-context server-tool shape and smallest-sufficient-research prompt.
- `lib/context_bot/research/runner.ex` — eliminate automatic resend after ambiguous provider exposure.
- `lib/context_bot/workers/deferred_worker.ex` — delegate stale-work classification to shared recovery.
- `lib/context_bot/application.ex` — place startup recovery before Oban.
- `justfile` — retain dotenv loading and disable the Erlang BREAK menu for interruptible dry runs.
- `test/context_bot/application_test.exs`, `test/context_bot/dry_run_test.exs`, `test/context_bot/dry_run/runtime_test.exs`, `test/mix/tasks/context_bot.dry_run_test.exs` — integration contracts.
- `test/context_bot/settings_test.exs`, `test/context_bot/research/request_test.exs`, `test/context_bot/research/runner_test.exs`, `test/context_bot/research/budget_test.exs`, `test/context_bot/workers/deferred_worker_test.exs` — changed cost and recovery behavior.
- `.env.example`, `fly.toml`, `README.md` — operator-visible settings and behavior.

---

### Task 1: Safe global JSONL logging

**Files:**
- Create: `lib/context_bot/logging.ex`
- Create: `lib/context_bot/logging/json_formatter.ex`
- Create: `test/context_bot/logging_test.exs`
- Create: `test/context_bot/logging/json_formatter_test.exs`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Modify: `lib/context_bot/operations.ex`
- Modify: `test/context_bot/operations_test.exs`
- Modify: `.env.example`
- Modify: `test/context_bot_web/production_config_test.exs`

**Interfaces:**
- Produces: `ContextBot.Logging.handler_config(nil | String.t()) :: keyword()`.
- Produces: `ContextBot.Logging.JSONFormatter.format(:logger.log_event(), map()) :: IO.chardata()`.
- Produces: Logger events with JSON keys `timestamp`, `severity`, `message`, plus only allowlisted scalar metadata keys.
- Consumes: `CONTEXT_BOT_LOG_PATH` only in `config/runtime.exs`; the path value itself must never enter an error or log event.

- [ ] **Step 1: Write formatter redaction tests**

Create table-driven tests that call the formatter directly. Assert each result is a single newline-terminated JSON object, timestamps and levels are normalized, and nested/sensitive metadata is excluded:

```elixir
event = %{
  level: :info,
  msg: {:string, "research_finished"},
  meta: %{
    time: 1_786_386_000_000_000,
    invocation_id: 42,
    stage: :researching,
    duration_ms: 125,
    raw_thread: "never log this",
    request: %{"messages" => ["secret prompt"]},
    api_key: "sk-ant-secret"
  }
}

line = event |> JSONFormatter.format(%{}) |> IO.iodata_to_binary()
assert String.ends_with?(line, "\n")
refute String.contains?(String.trim_trailing(line), "\n")
assert %{
         "severity" => "info",
         "message" => "research_finished",
         "invocation_id" => 42,
         "stage" => "researching",
         "duration_ms" => 125
       } = Jason.decode!(line)
refute line =~ "never log this"
refute line =~ "secret prompt"
refute line =~ "sk-ant-secret"
```

Cover charlists/format tuples and crashes containing arbitrary inspected data with message replaced by `"logger_event"`, and scalar allowlisted keys such as `job_id`, `queue`, `attempt_kind`, `attempt_index`, `input_tokens`, `output_tokens`, `tool_uses`, `cost_microdollars`, `failure_category`, and `failure_reason`.

- [ ] **Step 2: Run formatter tests and verify the missing-module failure**

Run: `direnv exec . mix test test/context_bot/logging/json_formatter_test.exs`

Expected: FAIL because `ContextBot.Logging.JSONFormatter` is undefined.

- [ ] **Step 3: Implement the allowlisting JSON formatter**

Implement a formatter with a fixed `MapSet` of safe metadata keys. Normalize atoms/numbers/booleans to JSON scalars, reject maps/lists/tuples/PIDs/references, convert the timestamp from Logger metadata, and end with exactly one newline:

```elixir
defmodule ContextBot.Logging.JSONFormatter do
  @safe_metadata MapSet.new(~w(
    invocation_id job_id queue worker attempt attempt_kind attempt_index stage duration_ms
    input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens
    tool_uses web_search_uses cost_microdollars failure_category failure_reason
    request_id method path status status_code
  )a)

  @spec format(:logger.log_event(), map()) :: IO.chardata()
  def format(%{level: level, msg: message, meta: metadata}, _config) do
    base = %{
      timestamp: timestamp(metadata[:time]),
      severity: Atom.to_string(level),
      message: safe_message(message)
    }

    metadata
    |> Enum.reduce(base, &put_safe_metadata/2)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  rescue
    _ -> Jason.encode!(%{severity: "error", message: "logger_format_error"}) <> "\n"
  end
end
```

Accept a message only when it is an atom or a binary matching `~r/\A[a-z][a-z0-9_.-]{0,127}\z/`; otherwise emit the fixed name `logger_event`. This keeps application event names while ensuring arbitrary interpolated strings, report structures, format tuples, and crashes cannot leak content through `message`. Never use `inspect/1` on an untrusted Logger value.

- [ ] **Step 4: Run formatter tests to green**

Run: `direnv exec . mix test test/context_bot/logging/json_formatter_test.exs`

Expected: PASS.

- [ ] **Step 5: Write destination/configuration tests**

In `logging_test.exs`, use a unique path beneath `System.tmp_dir!()` and assert:

```elixir
assert [config: [type: :standard_error], formatter: {JSONFormatter, %{}}] =
         Logging.handler_config(nil)

assert [config: [file: String.to_charlist(absolute_path)], formatter: {JSONFormatter, %{}}] =
         Logging.handler_config(absolute_path)
```

Open the configured path in append mode twice, write two JSON lines through `:logger_std_h`, and assert both remain. Assert `"logs/context.jsonl"`, a directory, and a path with an unwritable parent raise `ArgumentError` containing only `invalid CONTEXT_BOT_LOG_PATH`—not the rejected value.

Extend `production_config_test.exs` to run `config/runtime.exs` in its isolated subprocess with default, valid absolute, and relative log paths. Assert the resulting `:logger, :default_handler` config and fail-closed relative-path exit.

- [ ] **Step 6: Run destination tests and verify failure**

Run: `direnv exec . mix test test/context_bot/logging_test.exs test/context_bot_web/production_config_test.exs`

Expected: FAIL because `Logging.handler_config/1` and runtime handler configuration do not exist.

- [ ] **Step 7: Implement destination validation and configure Logger globally**

Implement `handler_config/1` with these exact branches:

```elixir
def handler_config(path) when path in [nil, ""], do: handler(:standard_error)

def handler_config(path) when is_binary(path) do
  if Path.type(path) == :absolute and regular_append_target?(path) do
    handler(String.to_charlist(path))
  else
    raise ArgumentError, "invalid CONTEXT_BOT_LOG_PATH"
  end
end
```

Validate appendability with `File.open(path, [:append, :utf8])` and close immediately; reject existing directories. In `config/runtime.exs`, configure:

```elixir
config :logger, :default_handler,
  ContextBot.Logging.handler_config(System.get_env("CONTEXT_BOT_LOG_PATH"))
```

Replace formatter overrides in `config/config.exs` and `config/dev.exs` with the JSON handler. Add `log: false` to every environment's `ContextBot.Repo` configuration so Ecto query SQL and bound parameters are off by default. Keep test Logger level `:warning`.

Change `Operations.log_attempt/3` from an interpolated JSON message to an event name with scalar metadata:

```elixir
Logger.info("context_bot_attempt", Map.to_list(payload))
```

Update `operations_test.exs` to capture the formatted event and assert its safe fields remain top-level JSON. Add `CONTEXT_BOT_LOG_PATH=` with an explanatory comment to `.env.example`; leave it unset in `fly.toml` so deployed logs continue to stderr.

- [ ] **Step 8: Verify logging behavior and content suppression**

Run: `direnv exec . mix test test/context_bot/logging_test.exs test/context_bot/logging/json_formatter_test.exs test/context_bot_web/production_config_test.exs`

Expected: PASS, including a captured Repo query whose stored invocation text never appears in captured logs.

- [ ] **Step 9: Commit the logging increment**

```bash
git add config .env.example lib/context_bot/logging.ex lib/context_bot/logging lib/context_bot/operations.ex test/context_bot/logging_test.exs test/context_bot/logging test/context_bot/operations_test.exs test/context_bot_web/production_config_test.exs
git commit -m "feat: add safe structured logging"
```

---

### Task 2: Stage-aware dry-run progress

**Files:**
- Create: `lib/context_bot/dry_run/progress.ex`
- Create: `test/context_bot/dry_run/progress_test.exs`
- Modify: `lib/context_bot/dry_run.ex`
- Modify: `test/context_bot/dry_run_test.exs`
- Modify: `lib/mix/tasks/context_bot.dry_run.ex`
- Modify: `test/mix/tasks/context_bot.dry_run_test.exs`

**Interfaces:**
- Produces: `ContextBot.DryRun.Progress.start(Invocation.t(), keyword()) :: state()`.
- Produces: `ContextBot.DryRun.Progress.update(state(), Invocation.t()) :: state()`.
- Produces: `ContextBot.DryRun.Progress.tick(state()) :: state()` and `finish(state()) :: :ok`.
- Produces: `ContextBot.DryRun.await/2` option `on_update: (Invocation.t() -> any())`; callback runs immediately and only on persisted stage changes.
- Consumes: injected `:io`, `:tty?`, and `:monotonic_ms`; production defaults are stdout, `IO.ANSI.enabled?() and match?({:ok, _}, :io.columns(io))`, and monotonic milliseconds.

- [ ] **Step 1: Write deterministic progress renderer tests**

Use `StringIO.open("")` and an injected clock. Assert non-TTY updates render exactly:

```text
dry_run_id=42 stage=capturing_thread elapsed=0s fetching selected post and ancestors
dry_run_id=42 stage=thread_ready elapsed=2s thread snapshot stored; queued for research
dry_run_id=42 stage=researching elapsed=3s waiting for Claude research (may take up to 300s)
```

Repeated `update/2` calls for the same stage must not write another line. TTY `tick/1` must write carriage-return spinner frames (`|`, `/`, `-`, `\\`) on one line, and `finish/1` must clear the line with ANSI erase-line before terminal output. Unknown stages render a bounded `working` label without inspecting the invocation.

- [ ] **Step 2: Run progress tests and verify missing-module failure**

Run: `direnv exec . mix test test/context_bot/dry_run/progress_test.exs`

Expected: FAIL because `ContextBot.DryRun.Progress` is undefined.

- [ ] **Step 3: Implement the pure progress state machine**

Keep the state limited to non-sensitive values:

```elixir
@type state :: %__MODULE__{
  id: pos_integer(),
  stage: atom() | nil,
  started_ms: integer(),
  frame: non_neg_integer(),
  tty?: boolean(),
  io: IO.device(),
  monotonic_ms: (() -> integer()),
  anthropic_timeout_ms: pos_integer()
}
```

Map only the durable stages from the approved design. Use integer elapsed seconds. `update/2` changes the persisted stage and renders it; `tick/1` advances the spinner only for TTY. Never include question, actor handle, target URI, answer, failure detail, or response data.

- [ ] **Step 4: Run progress tests to green**

Run: `direnv exec . mix test test/context_bot/dry_run/progress_test.exs`

Expected: PASS.

- [ ] **Step 5: Add callback tests to `DryRun.await/2`**

Insert/update an invocation through `:capturing_thread`, `:thread_ready`, and `:researching` using the injected `sleep` function. Collect callback stages and assert exactly `[:capturing_thread, :thread_ready, :researching, :complete]`. Add a polling test where the row remains unchanged for three sleeps and assert only one callback. Preserve all existing return values for complete, failed, deferred, timeout, missing, and invalid input.

- [ ] **Step 6: Run await tests and verify callback failure**

Run: `direnv exec . mix test test/context_bot/dry_run_test.exs`

Expected: FAIL because `await/2` ignores `on_update`.

- [ ] **Step 7: Thread stage changes through the wait loop**

Validate `on_update` as arity 1, add `last_stage` to `await_loop/7`, call the callback before terminal matching whenever `invocation.stage != last_stage`, and return the existing contract unchanged. Do not log or inspect the invocation.

- [ ] **Step 8: Integrate progress with the Mix task**

Change the test service contract to `await(invocation, options)` and assert it receives an `:on_update` callback. Capture the foreground PID before spawning the monitored await task so callback messages do not get sent back to the poller itself:

```elixir
Mix.shell().info("dry_run_id=#{invocation.id}")
progress = Progress.start(invocation, anthropic_timeout_ms: settings.anthropic_http_timeout_ms)
owner = self()
await_task = Task.async(fn ->
  service.await(invocation, on_update: fn current -> send(owner, {:progress, current}) end)
end)
result = await_foreground(await_task, progress)
Progress.finish(progress)
print_result(result)
```

Use a small foreground loop if animation ticks are needed while `await/2` blocks: run `service.await/2` in a monitored task, receive `{:progress, invocation}`, `:tick`, and `{ref, result}`, and call `Progress.tick/1` on a 100 ms timeout. Ensure `Progress.finish/1` executes in `after` for success, deferred, failure, timeout, and raised exceptions. Remove duplicate `dry_run_id` lines from terminal summaries because the ID is printed immediately after creation.

- [ ] **Step 9: Verify task output on TTY and non-TTY fakes**

Run: `direnv exec . mix test test/context_bot/dry_run_test.exs test/context_bot/dry_run/progress_test.exs test/mix/tasks/context_bot.dry_run_test.exs`

Expected: PASS; compact final `key=value` output remains intact and no ANSI codes appear for non-TTY output.

- [ ] **Step 10: Commit progress rendering**

```bash
git add lib/context_bot/dry_run.ex lib/context_bot/dry_run/progress.ex lib/mix/tasks/context_bot.dry_run.ex test/context_bot/dry_run_test.exs test/context_bot/dry_run/progress_test.exs test/mix/tasks/context_bot.dry_run_test.exs
git commit -m "feat: show durable dry-run progress"
```

---

### Task 3: Lower ordinary Anthropic research cost

**Files:**
- Modify: `lib/context_bot/settings.ex`
- Modify: `lib/context_bot/research/request.ex`
- Modify: `lib/context_bot/research/runner.ex`
- Modify: `test/context_bot/settings_test.exs`
- Modify: `test/context_bot/research/request_test.exs`
- Modify: `test/context_bot/research/runner_test.exs`
- Modify: `.env.example`
- Modify: `fly.toml`

**Interfaces:**
- Produces: `Settings.t().anthropic_effort :: :low | :medium | :high`.
- Produces: environment key `ANTHROPIC_EFFORT`; `Settings.load/1` accepts `anthropic_effort` in keyword/map inputs.
- Changes `Request.config()` to require `:effort` and emits the validated value as an Anthropic string.
- Preserves existing `anthropic_research_reservation_microdollars` and pricing behavior.

- [ ] **Step 1: Write settings defaults and validation tests**

Assert the default settings exactly:

```elixir
settings = Settings.load(%{})
assert settings.anthropic_effort == :medium
assert settings.anthropic_research_max_tokens == 4_096
assert settings.max_web_search_uses == 2
assert settings.max_web_fetch_uses == 2
assert settings.max_web_fetch_content_tokens == 10_000
assert settings.max_tool_continuations == 1
assert settings.anthropic_research_reservation_microdollars == 5_000_000
```

Assert strings `low`, `medium`, and `high` load as atoms, while blank, `minimal`, uppercase, and non-string values fail with `invalid ANTHROPIC_EFFORT`. Retain existing override/range tests for all numeric limits.

- [ ] **Step 2: Run settings tests and verify old-default failures**

Run: `direnv exec . mix test test/context_bot/settings_test.exs`

Expected: FAIL on the missing effort field and current 8192/5/5/50000/3 defaults.

- [ ] **Step 3: Add effort and new defaults to Settings**

Add `:anthropic_effort` to `@enforce_keys`, `defstruct`, `t()`, load construction, and startup validation. Parse with an explicit private function:

```elixir
defp anthropic_effort!(value) when value in ["low", "medium", "high"],
  do: String.to_existing_atom(value)

defp anthropic_effort!(_value), do: raise(ArgumentError, "invalid ANTHROPIC_EFFORT")
```

Change only the approved defaults. Do not change the maximum validation bounds, model, API version, tool versions, context window, or $5 research reservation.

- [ ] **Step 4: Run settings tests to green**

Run: `direnv exec . mix test test/context_bot/settings_test.exs`

Expected: PASS.

- [ ] **Step 5: Write exact request-shape tests**

Update `request_test.exs` so the complete tool assertions require:

```elixir
assert request["output_config"] == %{"effort" => "medium"}

assert Enum.at(request["tools"], 0) == %{
  "type" => "web_search_20260318",
  "name" => "web_search",
  "response_inclusion" => "excluded",
  "max_uses" => 2
}

assert Enum.at(request["tools"], 1) == %{
  "type" => "web_fetch_20260318",
  "name" => "web_fetch",
  "response_inclusion" => "excluded",
  "max_uses" => 2,
  "max_content_tokens" => 10_000,
  "citations" => %{"enabled" => true}
}

refute get_in(request, ["tools", Access.at(0), "allowed_callers"])
refute get_in(request, ["tools", Access.at(1), "use_cache"])
```

Assert continuation and length repair preserve `output_config` and tool configuration. Assert the system prompt contains the instruction to use the smallest research sufficient for a defensible 300-character answer.

- [ ] **Step 6: Run request tests and verify old-shape failures**

Run: `direnv exec . mix test test/context_bot/research/request_test.exs`

Expected: FAIL because effort is hard-coded high and direct/full/cache-bypass fields remain.

- [ ] **Step 7: Implement request shape and runner wiring**

Require `effort` in `Request.config()`, convert the atom using `Atom.to_string/1`, use excluded response inclusion, and omit `allowed_callers` and `use_cache`. Add to the system prompt:

```text
Use the smallest amount of web research sufficient for a defensible reply of at most 300
characters. Stop researching once the material claim is adequately supported or qualified.
```

Pass `settings.anthropic_effort` from `Runner.build_initial_request/2`. Update fixture settings builders in runner tests.

- [ ] **Step 8: Verify request and runner suites**

Run: `direnv exec . mix test test/context_bot/research/request_test.exs test/context_bot/research/runner_test.exs`

Expected: PASS, with fake providers only.

- [ ] **Step 9: Update checked-in operator defaults**

Set these exact non-secret values in `.env.example` and `fly.toml`:

```text
ANTHROPIC_EFFORT=medium
ANTHROPIC_RESEARCH_MAX_TOKENS=4096
MAX_WEB_SEARCH_USES=2
MAX_WEB_FETCH_USES=2
MAX_WEB_FETCH_CONTENT_TOKENS=10000
MAX_TOOL_CONTINUATIONS=1
```

Do not add `ANTHROPIC_API_KEY`, Bitwarden values, or any other secret.

- [ ] **Step 10: Commit cost controls**

```bash
git add lib/context_bot/settings.ex lib/context_bot/research/request.ex lib/context_bot/research/runner.ex test/context_bot/settings_test.exs test/context_bot/research/request_test.exs test/context_bot/research/runner_test.exs .env.example fly.toml
git commit -m "feat: reduce ordinary research cost"
```

---

### Task 4: Make ambiguous provider exposure terminal

**Files:**
- Modify: `lib/context_bot/research/runner.ex`
- Modify: `test/context_bot/research/budget_test.exs`
- Modify: `test/context_bot/research/runner_test.exs`
- Modify: `test/context_bot/workers/research_worker_test.exs`

**Interfaces:**
- Consumes and preserves: existing `Budget.mark_indeterminate(BudgetEntry.t(), DateTime.t(), claim_token()) :: {:ok, BudgetEntry.t()} | {:error, :stale_claim}`.
- Changes runner semantics: every `sent` entry without a committed `ResponseEnvelope` returns `{:error, :interrupted_after_send}` without calling the client.
- Preserves safe continuation from a `recorded` entry and explicit bounded retries after a persisted HTTP 429/5xx envelope.

- [ ] **Step 1: Strengthen ledger transition characterization tests**

Create a reserved entry, expose it, call `mark_indeterminate/3` twice with the owning claim, and assert there is still one entry with `state: :indeterminate`, unchanged reserved microdollars, and nil settled amount. Assert reserved/recorded/settled entries remain unchanged, a stale claim is rejected, and `Budget.reconcile_attempt/3` turns a sent/no-envelope row into the same indeterminate state.

- [ ] **Step 2: Run budget tests and preserve the existing ledger contract**

Run: `direnv exec . mix test test/context_bot/research/budget_test.exs`

Expected: PASS. This is a characterization gate for the existing durable primitive before runner semantics change.

- [ ] **Step 3: Add runner ambiguity tests before changing behavior**

Cover three paths with a fake client that sends `:client_called` if invoked:

1. Existing `sent` entry and no envelope: runner returns `{:error, :interrupted_after_send}`, marks indeterminate, and never sends `:client_called`.
2. The client returns `{:error, :timeout}` after exposure: runner returns the same terminal error and leaves one indeterminate entry; rerunning still does not call the client.
3. Existing `recorded` envelope: runner parses/resumes it and does not call the client.

Update the research worker test to assert `failure_category: :provider_response`, safe `failure_detail: %{\"reason\" => \"interrupted_after_send\"}`, no replacement research job, and no reply job.

- [ ] **Step 4: Run runner/worker tests and verify retry behavior fails**

Run: `direnv exec . mix test test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs`

Expected: FAIL because current reconciliation may reserve and send another attempt.

- [ ] **Step 5: Remove ambiguous retry branches**

In both pre-send reconciliation and transport/timeout handling, use:

```elixir
with {:ok, _entry} <-
       config.budget.mark_indeterminate(entry, now(config), config.claim_token) do
  {:error, :interrupted_after_send}
end
```

Do not call `reserve_attempt/…`, `client.run/1`, continuation logic, or repair logic after this result. Keep retries only where an actual HTTP response envelope was durably stored and its decoded finite category explicitly permits another attempt.

- [ ] **Step 6: Verify ambiguity and existing success/retry coverage**

Run: `direnv exec . mix test test/context_bot/research/budget_test.exs test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs`

Expected: PASS; assertions prove call count is zero after ambiguous recovery.

- [ ] **Step 7: Commit terminal ambiguity behavior**

```bash
git add lib/context_bot/research/runner.ex test/context_bot/research/budget_test.exs test/context_bot/research/runner_test.exs test/context_bot/workers/research_worker_test.exs
git commit -m "fix: never retry ambiguous Anthropic calls"
```

---

### Task 5: Centralize orphan recovery

**Files:**
- Create: `lib/context_bot/workflow/recovery.ex`
- Create: `test/context_bot/workflow/recovery_test.exs`
- Modify: `lib/context_bot/workers/deferred_worker.ex`
- Modify: `test/context_bot/workers/deferred_worker_test.exs`

**Interfaces:**
- Produces: `Recovery.recover_orphans(keyword()) :: {:ok, %{examined: non_neg_integer(), resumed: non_neg_integer(), terminalized: non_neg_integer(), unchanged: non_neg_integer()}}`.
- Produces: `Recovery.recover_invocation(Invocation.t(), keyword()) :: :resumed | :terminalized | :unchanged`.
- Options: `now: DateTime.t()`, `startup?: boolean()`, `job_states: [String.t()]`, and `settings: Settings.t()`; default runtime mode considers lease-expired work, startup mode considers all `executing` jobs orphaned.
- Consumes: the `Budget.mark_indeterminate/3` state-transition contract, `ResponseEnvelope`, invocation claims, and existing Oban job rows; recovery applies the equivalent budget update inside its shared transaction.
- Queue mapping: dry invocations use only `dry_thread`/`dry_research`; public invocations use `eligibility`/`thread`/`research`/`reply`.

- [ ] **Step 1: Write the full recovery-matrix database tests**

Use real SQLite sandbox rows and Oban jobs. Add one test per approved matrix row:

- abandoned eligibility/thread job becomes `available` in the correct dry/public queue;
- researching with no budget entry clears the stale claim, returns to `thread_ready`, and has exactly one research job;
- a latest `reserved` entry is reused, not duplicated, and research is made available;
- `sent` without envelope becomes one indeterminate entry and terminal invocation with `provider_response/interrupted_after_send`; the old job is discarded and no new job exists;
- `recorded` envelope makes research available for local processing without a new entry;
- abandoned deterministic publication returns to `reply` only for public work;
- deferred and terminal invocations are unchanged;
- dry work never produces `eligibility`, `thread`, `research`, or `reply` queue jobs;
- invoking `recover_orphans/1` twice leaves identical invocation/budget state and exactly one resumable job.

Construct an orphan by inserting a valid Oban job and updating `state: "executing"`, `attempted_at`, and `attempted_by`. Runtime freshness is exact: identity/eligibility uses `max(atproto_http_timeout_ms, atproto_session_timeout_ms) + 30_000`, thread capture uses `thread_fetch_timeout_ms + 30_000`, research uses the existing 21,600,000 ms claim lease, and publication uses the existing 300,000 ms claim lease. Inject `now` just before and just after each boundary to prove fresh work is unchanged and stale work is recovered.

- [ ] **Step 2: Run recovery tests and verify missing-module failure**

Run: `direnv exec . mix test test/context_bot/workflow/recovery_test.exs`

Expected: FAIL because `ContextBot.Workflow.Recovery` is undefined.

- [ ] **Step 3: Implement bounded orphan selection and classification**

Select at most 100 candidates per pass, ordered by oldest `attempted_at` and ID. Join jobs to invocations through `args["uri"]` and `args["cid"]`; skip malformed/unowned jobs. Keep the per-candidate write in `Repo.transaction(mode: :immediate)` and re-read all rows inside it before applying a transition.

Use private classifiers returning explicit actions:

```elixir
@type action ::
  {:make_available, String.t()} |
  {:resume_research, BudgetEntry.t() | nil} |
  :terminalize_ambiguous_research |
  :resume_stored_response |
  :resume_publication |
  :unchanged
```

For resumption, prefer making the existing orphan job `available`; insert a replacement only when no matching nonterminal job exists. Use existing unique args/worker semantics and a conditional update so concurrent passes cannot duplicate work. Clear only the claim belonging to the orphaned stage. For the ambiguous branch, update the budget row directly inside this same transaction with the exact state transition characterized for `Budget.mark_indeterminate/3`; do not open a nested transaction, and cover parity in the Task 5 tests.

- [ ] **Step 4: Run recovery tests incrementally to green**

Run: `direnv exec . mix test test/context_bot/workflow/recovery_test.exs`

Expected: PASS for all matrix and idempotence cases.

- [ ] **Step 5: Refactor maintenance recovery to call the shared module**

Add an injected dependency `recovery: ContextBot.Workflow.Recovery`. Retain deferred-budget due-time admission in `DeferredWorker`, but replace its stale job/claim classification paths with:

```elixir
{:ok, _summary} = recovery.recover_orphans(now: now, startup?: false)
```

Do not enable `Oban.Plugins.Lifeline`. Preserve batch/fairness limits and normal scheduled cadence.

- [ ] **Step 6: Update maintenance tests for shared semantics**

Keep existing deferred admission assertions. Change stale sent/no-envelope expectations from replacement research jobs to terminal indeterminate state. Add a fake recovery dependency assertion and retain the fresh-lease tests.

Run: `direnv exec . mix test test/context_bot/workers/deferred_worker_test.exs test/context_bot/workflow/recovery_test.exs`

Expected: PASS.

- [ ] **Step 7: Commit shared recovery**

```bash
git add lib/context_bot/workflow/recovery.ex lib/context_bot/workers/deferred_worker.ex test/context_bot/workflow/recovery_test.exs test/context_bot/workers/deferred_worker_test.exs
git commit -m "feat: centralize interruption recovery"
```

---

### Task 6: Run recovery before queues start

**Files:**
- Create: `lib/context_bot/workflow/startup_recovery.ex`
- Create: `test/context_bot/workflow/startup_recovery_test.exs`
- Modify: `lib/context_bot/application.ex`
- Modify: `test/context_bot/application_test.exs`
- Modify: `lib/context_bot/dry_run/runtime.ex`
- Modify: `test/context_bot/dry_run/runtime_test.exs`

**Interfaces:**
- Produces: `StartupRecovery.start_link(keyword()) :: GenServer.on_start()`.
- `StartupRecovery.init/1` synchronously calls `recovery.recover_orphans(startup?: true, now: now.())`; it returns `{:ok, state}` only after recovery succeeds and returns `{:stop, :startup_recovery_failed}` otherwise.
- Changes `Application.bot_children/1` order to `[StartupRecovery, Oban, Session, Poller]`.
- Changes `DryRun.Runtime.ensure_started/1` (default options `[]`) to recover before starting or accepting dry Oban producers.
- Produces: `DryRun.Runtime.stop(keyword()) :: :ok`, which pauses dry queues and stops the standalone Oban supervisor with the configured shutdown grace period.

- [ ] **Step 1: Write synchronous startup child tests**

Use a fake recovery module that sends `{:recover, options}` and can return success/error. Assert `start_link/1` does not return until the fake recovery completes, remains alive and idle after success, and stops safely without exposing the fake reason after failure.

- [ ] **Step 2: Run startup child tests and verify failure**

Run: `direnv exec . mix test test/context_bot/workflow/startup_recovery_test.exs`

Expected: FAIL because `StartupRecovery` is undefined.

- [ ] **Step 3: Implement the idle-after-init GenServer**

```elixir
def init(options) do
  recovery = Keyword.get(options, :recovery, ContextBot.Workflow.Recovery)
  now = Keyword.get(options, :now, &DateTime.utc_now/0)

  case recovery.recover_orphans(startup?: true, now: now.()) do
    {:ok, summary} -> {:ok, %{summary: summary}}
    {:error, _safe_reason} -> {:stop, :startup_recovery_failed}
  end
end
```

Log only the safe summary counts from Task 5.

- [ ] **Step 4: Write supervision-order tests**

Update `application_test.exs` to assert enabled children have IDs `[StartupRecovery, Oban, Session, Poller]` and disabled server mode still starts no bot-only consumers. Add an integration fake proving recovery receives its message before an instrumented Oban child starts.

- [ ] **Step 5: Insert startup recovery before public Oban**

Use `{ContextBot.Workflow.StartupRecovery, []}` immediately before the existing Oban child. Preserve Session/Poller order and all disabled-bot behavior.

- [ ] **Step 6: Add dry-runtime ordering and safety tests**

Inject a recovery dependency into `Runtime.ensure_started/1`. Assert it runs after `ContextBot.Repo` is available but before either `dry_thread` or `dry_research` producer exists. Assert recovery failure returns `{:error, :startup_recovery_failed}` and leaves Oban stopped. Keep exact queue limit/plugin safety tests.

- [ ] **Step 7: Call shared recovery before dry queues**

Add:

```elixir
@spec ensure_started(keyword()) :: :ok | {:error, atom()}
def ensure_started(options \\ []) do
  recovery = Keyword.get(options, :recovery, ContextBot.Workflow.Recovery)
  # ensure Repo application, reject public children, recover, then ensure Oban
end
```

If a safe dry Oban is already running, do not classify its current `executing` jobs as startup orphans. Recovery is mandatory only before this invocation starts the dry Oban instance.

Implement `Runtime.stop/1` by calling `Oban.pause_all_queues/1` and `Supervisor.stop/3` on the standalone Oban PID. Derive the timeout from Oban's `:shutdown_grace_period` plus 1,000 ms. It must be idempotent when Oban is absent and must never stop a public Oban instance.

- [ ] **Step 8: Verify startup ordering**

Run: `direnv exec . mix test test/context_bot/application_test.exs test/context_bot/dry_run/runtime_test.exs test/context_bot/workflow/startup_recovery_test.exs test/context_bot/workflow/recovery_test.exs`

Expected: PASS; no Oban producer is active before successful recovery.

- [ ] **Step 9: Commit startup recovery ordering**

```bash
git add lib/context_bot/application.ex lib/context_bot/dry_run/runtime.ex lib/context_bot/workflow/startup_recovery.ex test/context_bot/application_test.exs test/context_bot/dry_run/runtime_test.exs test/context_bot/workflow/startup_recovery_test.exs
git commit -m "feat: recover orphaned work before dispatch"
```

---

### Task 7: Clean dry-run interruption handling

**Files:**
- Create: `lib/context_bot/dry_run/interrupts.ex`
- Create: `test/context_bot/dry_run/interrupts_test.exs`
- Modify: `lib/context_bot/dry_run.ex`
- Modify: `lib/context_bot/dry_run/runtime.ex`
- Modify: `lib/mix/tasks/context_bot.dry_run.ex`
- Modify: `justfile`
- Modify: `test/context_bot/dry_run_test.exs`
- Modify: `test/context_bot/dry_run/runtime_test.exs`
- Modify: `test/mix/tasks/context_bot.dry_run_test.exs`

**Interfaces:**
- Produces: `Interrupts.install(pid(), keyword()) :: {:ok, token()}` and `Interrupts.remove(token(), keyword()) :: :ok`; both option lists default to `[]` and carry injected trap/untrap functions in tests.
- Delivers `{:context_bot_interrupt, :sigint | :sigterm}` to the owner without doing database work inside the signal callback.
- Adds `DryRun.await/2` option `interrupt?: (() -> boolean())`; interruption returns `{:error, :interrupted}`.
- The Mix task stops the foreground await task, clears progress, calls `DryRun.Runtime.stop/1` for a graceful Oban shutdown, and exits with a finite safe error containing the durable invocation ID.
- The `dry-run` recipe starts the VM with `+B` so Ctrl-C produces SIGINT instead of the Erlang BREAK menu; it also retains `set dotenv-load := true`.

- [ ] **Step 1: Write scoped signal registration tests**

Inject `trap_signal` and `untrap_signal` functions so tests do not signal the test VM. Assert installation registers both `:sigint` and `:sigterm` with a unique token, each callback only sends the owner a small atom tuple, and `remove/1` unregisters both even when one untrap call fails.

- [ ] **Step 2: Run interrupt tests and verify missing-module failure**

Run: `direnv exec . mix test test/context_bot/dry_run/interrupts_test.exs`

Expected: FAIL because `ContextBot.DryRun.Interrupts` is undefined.

- [ ] **Step 3: Implement scoped traps**

Use `System.trap_signal/3` and `System.untrap_signal/2` behind injectable functions. Never call Repo, Logger, Mix shell, Oban, or `Application.stop/1` inside a callback. The callback sends the owner and returns `:ok`.

- [ ] **Step 4: Add wait-loop interruption tests**

Use an injected function returning false once and true after one sleep. Assert `DryRun.await/2` returns `{:error, :interrupted}` promptly, while persisted invocation and job rows remain untouched. Assert invalid callbacks return `{:error, :invalid_input}`.

- [ ] **Step 5: Make the wait loop interrupt-aware**

Check `interrupt?.()` before each sleep and after wakeup. Do not mutate workflow state on foreground interruption; durable worker completion or Task 5 recovery owns the final state.

- [ ] **Step 6: Add Mix task cleanup tests**

Configure the fake service to block until killed. Trigger `{:context_bot_interrupt, :sigterm}` and assert:

- the progress line is cleared;
- the monitored await task terminates;
- the runtime receives `stop` exactly once after new dispatch is paused;
- the task prints `dry_run_id=…` and `status=interrupted` once;
- the safe error does not include question, URI, provider details, or API key;
- the signal handlers are removed in `after`.

Also keep success/failure/deferred tests to prove handlers and progress are cleaned up on every branch.

- [ ] **Step 7: Integrate interruption into the foreground receive loop**

Wrap installation/removal with `try/after`. On interrupt, call `Task.shutdown(await_task, 5_000)`, then `runtime.stop()` so Oban pauses dispatch and gives the executing worker its configured shutdown grace period. Return `{:error, :interrupted}` for the existing result printer. Do not terminalize the invocation directly: a provider response may still commit during the grace period, and startup/runtime recovery must classify any remaining orphan from durable state.

- [ ] **Step 8: Run unit and subprocess SIGTERM coverage**

Run: `direnv exec . mix test test/context_bot/dry_run/interrupts_test.exs test/context_bot/dry_run_test.exs test/context_bot/dry_run/runtime_test.exs test/mix/tasks/context_bot.dry_run_test.exs`

Add subprocess integration cases that launch a fake-provider dry task, wait for its printed invocation ID, send SIGTERM and SIGINT separately, and assert finite exit plus durable recoverability. They must use fake HTTP adapters and a temporary database. Update the `dry-run` recipe while preserving the user's dotenv setting:

```just
set dotenv-load := true

dry-run post question:
    #!/usr/bin/env bash
    set -euo pipefail
    source ./secrets.sh ANTHROPIC_API_KEY
    ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +B" \
      BOT_ENABLED=false mix context_bot.dry_run {{quote(post)}} {{quote(question)}}
```

Erlang's `+B` disables the emulator BREAK handler, allowing the scoped `System.trap_signal(:sigint, ...)` callback to receive Ctrl-C rather than showing the interactive BREAK prompt. Assert `just --dry-run dry-run ...` contains `+B` and that existing recipe tests still pass.

Expected: PASS; no live network request.

- [ ] **Step 9: Commit interruption handling**

```bash
git add justfile lib/context_bot/dry_run.ex lib/context_bot/dry_run/interrupts.ex lib/context_bot/dry_run/runtime.ex lib/mix/tasks/context_bot.dry_run.ex test/context_bot/dry_run_test.exs test/context_bot/dry_run/interrupts_test.exs test/context_bot/dry_run/runtime_test.exs test/mix/tasks/context_bot.dry_run_test.exs
git commit -m "feat: handle interrupted dry runs safely"
```

---

### Task 8: Operator documentation and end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `knowledge-base/learnings.md`
- Create: `knowledge-base/reports/2026-08-10-anthropic-cost-and-interruption-recovery.md`
- Modify: `test/context_bot/dry_run_workflow_test.exs`

**Interfaces:**
- Documents stderr/file JSONL logging, stdout progress, timeout expectations, new cost controls, and terminal ambiguous-request policy.
- Verifies the complete dry workflow with fake public/Anthropic providers and no publication.

- [ ] **Step 1: Add an end-to-end regression for the observed failure mode**

In `dry_run_workflow_test.exs`, construct a dry invocation, complete ancestor-only thread capture, expose an Anthropic budget entry, mark the research job executing, simulate process loss by leaving no response envelope, call startup recovery twice, and assert:

```elixir
assert invocation.stage == :failed
assert invocation.failure_category == :provider_response
assert invocation.failure_detail == %{"reason" => "interrupted_after_send"}
assert [%BudgetEntry{state: :indeterminate}] = budget_entries(invocation)
assert [] == provider_calls()
refute Repo.exists?(from j in Oban.Job, where: j.queue in ["research", "reply"] and j.state in ["available", "scheduled", "executing"])
```

Add the safe positive path: a committed fake response envelope resumes and completes with the concise answer, usage, and settled cost, still without a provider call or Bluesky publication.

- [ ] **Step 2: Run end-to-end regression to green**

Run: `direnv exec . mix test test/context_bot/dry_run_workflow_test.exs`

Expected: PASS.

- [ ] **Step 3: Update README operations guidance**

Document exact examples:

```bash
# JSONL logs to stderr; progress/final answer to stdout
just dry-run POST_URL "What's missing?"

# Append logs to a file while keeping progress on stdout
CONTEXT_BOT_LOG_PATH=/absolute/path/context-bot.jsonl \
  just dry-run POST_URL "What's missing?"
```

Explain that `researching` may last up to `ANTHROPIC_HTTP_TIMEOUT_MS`, ordinary settings target roughly $0.05 but are not a hard cap, the $5 reservation is not a charge, server-tool passes can accumulate context under one request ID, and an interruption after send intentionally fails as `interrupted_after_send` instead of risking a duplicate charge.

- [ ] **Step 4: Record the reusable debugging lesson**

Write a dated report with the observed durable state, same-request-ID server-tool behavior, price arithmetic, redaction issue, and recovery invariant. Add one sentence to `knowledge-base/learnings.md`:

```text
- Treat an Anthropic attempt as irreversibly exposed after its budget row reaches `sent`; without a committed response envelope, mark it indeterminate and never retry automatically.
```

- [ ] **Step 5: Run focused security scans**

Run:

```bash
rg -n 'raw_notification|raw_thread|anthropic_messages|selected_reply|raw_body|authorization|api_key' lib/context_bot/logging* lib/context_bot/dry_run* lib/context_bot/workflow/recovery.ex
rg -n 'allowed_callers|response_inclusion|use_cache|ANTHROPIC_EFFORT' lib config .env.example fly.toml test
```

Expected: sensitive field names appear only in explicit deny/redaction tests; no formatter or progress code emits their values. `allowed_callers` and `use_cache` occur only in negative assertions/documentation, and runtime request code uses `response_inclusion: "excluded"`.

- [ ] **Step 6: Run the complete quality gate**

Run: `direnv exec . just check`

Expected: formatting check, warnings-as-errors compilation, all ExUnit tests, Credo, ShellCheck, and Dialyzer pass.

- [ ] **Step 7: Build and smoke-test the production image**

Run: `direnv exec . just docker-build`

Start the image with a temporary SQLite path, `BOT_ENABLED=false`, valid `SECRET_KEY_BASE`, and no Anthropic/Bluesky secrets. Bind a temporary local port, request `/health`, and stop the container.

Expected: image starts, startup recovery completes before any queue consumer, `GET /health` returns HTTP 200, and stderr contains valid JSONL with no SQL parameter/body data.

- [ ] **Step 8: Request independent code review**

Use `superpowers:requesting-code-review` with focus on:

- whether any sent/no-envelope path can call Anthropic again;
- recovery transaction/idempotence races;
- dry/public queue separation;
- log and progress content leakage;
- production startup order;
- whether cost defaults and request shape match the approved spec.

Address findings with focused failing tests and rerun `just check`.

- [ ] **Step 9: Commit documentation and verified integration**

```bash
git add README.md knowledge-base test/context_bot/dry_run_workflow_test.exs
git commit -m "docs: explain hardened dry-run operations"
```

- [ ] **Step 10: Finish and integrate the branch**

Use `superpowers:verification-before-completion`, then `superpowers:finishing-a-development-branch`. Rebase or fast-forward without a merge commit. Before touching main, confirm its only uncommitted change is the user's `set dotenv-load := true`; preserve it exactly. Integrate `codex/operational-hardening` into main only after fresh verification, then report the resulting commit IDs and the commands actually run.
