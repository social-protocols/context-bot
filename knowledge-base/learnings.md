# Learnings

One-sentence facts and constraints distilled from investigations in this repo. Loaded into every agent's context — keep terse. Each line links to a longer report under `reports/` for full detail.

- Devbox 0.16 needs explicit Beam flake packages with the Elixir plugin disabled on current macOS nixpkgs. ([reports/2026-07-27-devbox-elixir-macos.md](reports/2026-07-27-devbox-elixir-macos.md))
- Export Nix's CA bundle as both `SSL_CERT_FILE` and `HEX_CACERTS_PATH` for Erlang HTTPS on macOS. ([reports/2026-07-27-devbox-elixir-macos.md](reports/2026-07-27-devbox-elixir-macos.md))
- Anthropic cited web research and strict JSON Schema output require separate Messages calls. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
- Local ATProto CIDs prove content identity; only PDS inclusion authenticates repository state. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
- IPFS adds no durability without operated or paid pins and gateways. ([reports/2026-07-27-audit-protocol-constraints.md](reports/2026-07-27-audit-protocol-constraints.md))
