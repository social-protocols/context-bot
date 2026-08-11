# Learnings

One-sentence facts and constraints distilled from investigations in this repo. Loaded into every agent's context — keep terse. Each line links to a longer report under `reports/` for full detail.

- Devbox 0.16 needs explicit Beam flake packages with the Elixir plugin disabled on current macOS nixpkgs. ([reports/2026-07-27-devbox-elixir-macos.md](reports/2026-07-27-devbox-elixir-macos.md))
- Export Nix's CA bundle as both `SSL_CERT_FILE` and `HEX_CACERTS_PATH` for Erlang HTTPS on macOS. ([reports/2026-07-27-devbox-elixir-macos.md](reports/2026-07-27-devbox-elixir-macos.md))
- Anthropic prompt caching requires an identical tools/system/messages prefix; keep optional length repair append-only and treat cache hits only as an optimization. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
- Local ATProto CIDs prove content identity; only PDS inclusion authenticates repository state. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
- IPFS adds no durability without operated or paid pins and gateways. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
- Request Skywatch labels from direct `api.bsky.app` and require its labeler-confirmation response header. ([reports/2026-07-28-live-eligibility-signals.md](reports/2026-07-28-live-eligibility-signals.md))
- Trust `bsky.team` only after bidirectional handle/DID verification; forward resolution can be stale. ([reports/2026-07-28-live-eligibility-signals.md](reports/2026-07-28-live-eligibility-signals.md))
- Poll notifications newest-first with `priority=false`; filtered empty pages can still carry a cursor. ([reports/2026-07-29-poc-provider-contracts.md](reports/2026-07-29-poc-provider-contracts.md))
- Mark Anthropic attempts sent before POST; replay of exposed attempts needs a new budget reservation. ([reports/2026-07-29-poc-provider-contracts.md](reports/2026-07-29-poc-provider-contracts.md))
- Freeze a TID reply record and reconcile GET/PUT results; never allocate a second rkey after ambiguity. ([reports/2026-07-29-poc-provider-contracts.md](reports/2026-07-29-poc-provider-contracts.md))
- Req 0.7 nests named-Finch timeouts under `finch:`; Oban SQLite uses `Oban.Engines.Lite`. ([reports/2026-07-29-poc-provider-contracts.md](reports/2026-07-29-poc-provider-contracts.md))
- Route authenticated `app.bsky.*` PDS calls with the explicit Bluesky AppView service-proxy header. ([reports/2026-08-02-live-boundary-hardening.md](reports/2026-08-02-live-boundary-hardening.md))
- Credential-owning GenServers must redact `format_status` and contain expected adapter exceptions. ([reports/2026-08-02-live-boundary-hardening.md](reports/2026-08-02-live-boundary-hardening.md))
- Provider storage must cover every permitted response body plus bounded envelope metadata. ([reports/2026-08-02-live-boundary-hardening.md](reports/2026-08-02-live-boundary-hardening.md))
- `Context`, `ContextBot`, and `GetContext` are crowded AI names; use a distinctive public brand and frame it as invoked research. ([reports/2026-08-10-context-name-collisions.md](reports/2026-08-10-context-name-collisions.md))
- Excluded web-tool results can still drive Anthropic input billing; bound tool use, fetched tokens, output, and effort. ([reports/2026-08-10-anthropic-cost-and-interruption-recovery.md](reports/2026-08-10-anthropic-cost-and-interruption-recovery.md))
- Never replay a sent Anthropic attempt without its committed response envelope; terminalize it as indeterminate. ([reports/2026-08-10-anthropic-cost-and-interruption-recovery.md](reports/2026-08-10-anthropic-cost-and-interruption-recovery.md))
- Elixir cannot trap SIGINT; CLI Ctrl-C needs `+B i` plus a shell bridge to a supported signal. ([reports/2026-08-10-elixir-cli-signals.md](reports/2026-08-10-elixir-cli-signals.md))
- Separate Mix VMs need a SQLite-path `flock` held through confirmed Oban death; VM-local names cannot serialize recovery. ([reports/2026-08-11-dry-run-process-fencing.md](reports/2026-08-11-dry-run-process-fencing.md))
- `BASH_ENV` DEBUG traps reach child Bash processes; test the `&`/`$!` race with an explicit wrapper seam. ([reports/2026-08-11-dry-run-process-fencing.md](reports/2026-08-11-dry-run-process-fencing.md))
