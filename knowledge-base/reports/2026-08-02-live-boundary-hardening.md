# Live boundary hardening

**Date:** 2026-08-02
**TL;DR:** The final branch review exposed three live-boundary assumptions that mocked happy paths did not catch: explicit AppView proxy routing, credential-safe GenServer crash formatting, and aggregate response-storage sizing.

## Context

The complete POC branch passed its task-level reviews and 318-test gate, but a whole-branch review was asked to trace the actual live request and recovery paths before merge.

## Investigation

The ATProto client sent authenticated `app.bsky.notification.listNotifications` and `app.bsky.feed.getPostThread` calls to the account PDS without a service selector. Bluesky's API-host guide says authenticated `app.bsky.*` calls flow through the user's PDS, while the ATProto service-proxy specification defines `atproto-proxy` as the explicit remote-service selector. The ATProto roadmap names the Bluesky AppView reference as `did:web:api.bsky.app#bsky_appview` and warns clients not to rely on legacy automatic forwarding:

- https://docs.bsky.app/docs/advanced-guides/api-directory
- https://atproto.com/specs/xrpc#service-proxying
- https://atproto.com/blog/2025-protocol-roadmap-spring

The same client let Req buffer and JSON-decode ATProto bodies before the thread worker re-encoded the map to measure it. The existing Anthropic client already demonstrated the correct repository pattern: request raw bytes, stream through `ContextBot.HTTP.BodyLimit`, then decode only a bounded body.

`ContextBot.ATProto.Session` kept the app password and both JWTs in ordinary GenServer state. `:sys.get_status/1` proved that OTP's default formatting exposed all three values, and a raised Req adapter exception terminated the process with its unredacted state available to crash reporting.

Finally, startup required only `storage_cap > response_cap`. Persisted response envelopes also charge metadata, and one workflow may record an initial response, every permitted continuation, one repair, and every permitted HTTP retry. A near-adjacent cap could therefore accept HTTP bytes that SQLite was not allowed to retain.

## Findings

- Authenticated Bluesky application RPCs through the PDS must explicitly send `atproto-proxy: did:web:api.bsky.app#bsky_appview`; repository RPCs must not.
- Response size enforcement belongs on raw streamed bytes before JSON decoding, not on a reconstructed decoded term.
- A process that owns credentials must redact `format_status` output and normalize expected adapter exceptions so crash reports cannot inspect secrets.
- Provider storage must cover `(1 + continuations + 1 repair + retries)` complete response bodies plus bounded envelope headroom.

## Implications

Contract tests should assert service-routing headers separately for application RPCs and repository RPCs. Any new credential-owning OTP process needs a status-formatting test using `:sys.get_status/1`. When attempt limits or response caps change, `ContextBot.Settings` must continue validating their aggregate storage product rather than treating the two byte caps independently.
