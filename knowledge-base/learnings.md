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
