# Devbox Elixir setup on macOS

**Date:** 2026-07-27
**TL;DR:** Devbox 0.16's built-in Elixir plugin referenced a removed macOS Nix attribute. Using explicit nixpkgs flake packages with the plugin disabled resolved Elixir/OTP, and exporting Nix's CA bundle fixed Erlang HTTPS discovery.

## Context

The repository needed a reproducible Devbox shell with Elixir 1.20 and Erlang/OTP 28 that worked with the developer's already-installed Devbox 0.16. A normal package declaration failed before the Phoenix application could be generated.

## Investigation

The initial `elixir@1.20` declaration activated Devbox's built-in Elixir plugin. Debug output showed that plugin injecting `darwin.apple_sdk.frameworks.CoreServices`, an attribute removed from current nixpkgs. Devbox 0.17.5 documents a fix, but requiring a host upgrade would weaken checkout compatibility.

The older Devbox package index also did not expose Elixir 1.20 by its short package name. Direct Nix flake evaluation confirmed current packages were available:

```bash
nix eval --raw github:NixOS/nixpkgs/nixpkgs-unstable#beam28Packages.elixir_1_20.version
nix eval --raw github:NixOS/nixpkgs/nixpkgs-unstable#beam28Packages.erlang.version
```

These resolved to Elixir 1.20.2 and OTP 28.5.0.3. Declaring the full flake attribute and setting `disable_plugin: true` bypassed the incompatible plugin while preserving a locked environment.

Phoenix generation then failed in `:pubkey_os_cacerts` with `:no_cacerts_found`. The shell already exposed a valid `NIX_SSL_CERT_FILE`, but Erlang and Hex were not consulting it under this Nix-built macOS runtime. Setting both `SSL_CERT_FILE` and `HEX_CACERTS_PATH` to that bundle changed the failure from certificate discovery to the expected sandbox DNS restriction, and HTTPS worked with network access.

## Findings

The working declarations are:

```json
"github:NixOS/nixpkgs/nixpkgs-unstable#beam28Packages.elixir_1_20": {
  "disable_plugin": true
},
"github:NixOS/nixpkgs/nixpkgs-unstable#beam28Packages.erlang": {}
```

The shell initialization must export:

```bash
export SSL_CERT_FILE="${NIX_SSL_CERT_FILE}"
export HEX_CACERTS_PATH="${NIX_SSL_CERT_FILE}"
```

Use `mix local.hex --if-missing --force` and `mix local.rebar --if-missing --force` during shell initialization so entering an already-prepared shell does not redownload them.

## Implications

- Do not replace the explicit Beam flake attributes with Devbox's short Elixir package name unless the minimum supported Devbox version is deliberately raised and tested.
- Keep the Elixir plugin disabled while supporting Devbox 0.16 on current nixpkgs.
- Preserve both CA-bundle exports; removing them breaks Mix/Phoenix HTTPS on this macOS Nix runtime.
- Verify the exact runtime with `direnv exec . elixir --version` after changing Devbox inputs.
