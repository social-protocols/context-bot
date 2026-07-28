# Live Eligibility Signals

**Date:** 2026-07-28
**TL;DR:** “Bluesky Elder” is a Skywatch custom label, not a native badge, and the live AppView must confirm that it honored the requested labeler. A `bsky.team` suffix is eligible only after current handle-to-DID and DID-to-handle claims agree.

## Context

The live Context Bot POC needs a low-friction admission gate before it spends money on Claude. The proposed signals were Skywatch's “Bluesky Elder” label and a `bsky.team` handle. Both needed a protocol-level rule that could not be spoofed with profile text or a stale handle.

## Investigation

The investigation checked the current Skywatch profile, labeler declaration and DID document; Bluesky's moderation guide; the ATProto label, handle, and DID specifications; identity-resolution Lexicons; and live AppView responses.

Relevant sources:

- [Bluesky moderation guide](https://docs.bsky.app/docs/advanced-guides/moderation)
- [ATProto label specification](https://atproto.com/specs/label)
- [ATProto handle specification](https://atproto.com/specs/handle)
- [ATProto DID specification](https://atproto.com/specs/did)
- [Skywatch labeler declaration](https://public.api.bsky.app/xrpc/app.bsky.labeler.getServices?dids=did%3Aplc%3Ae4elbtctnfqocyfcml6h2lf7&detailed=true)
- [Skywatch DID document](https://plc.directory/did:plc:e4elbtctnfqocyfcml6h2lf7)

## Findings

### Bluesky Elder

“Bluesky Elder” is the account-level custom label `bluesky-elder` issued by independent labeler Skywatch Blue. It is not a native profile field, first-party verification state, or text that should be read from a bio. Pin the labeler by DID:

```text
did:plc:e4elbtctnfqocyfcml6h2lf7
```

The simplest POC lookup is:

```http
GET https://api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=<actor DID>
atproto-accept-labelers: did:plc:e4elbtctnfqocyfcml6h2lf7
```

Require `atproto-content-labelers` in the response to include the pinned DID. Then accept only an active label with the pinned `src`, the actor DID as `uri`, exact `val` `bluesky-elder`, no true `neg`, and no expired `exp`.

In live checks, `public.api.bsky.app` did not honor the custom-labeler request and returned only the default labeler, while direct `api.bsky.app` returned Skywatch in the response header and the expected label. A missing Skywatch response-header entry therefore means unknown/unavailable, not a trustworthy negative result.

### bsky.team

Handles are mutable. A string ending in `.bsky.team`, or a successful forward `resolveHandle` call alone, is insufficient. The current normalized handle must equal `bsky.team` or end at the exact `.bsky.team` suffix boundary, resolve to the actor DID, and appear as the current valid handle claim in that actor's DID document.

A live counterexample showed why both directions matter: `why.bsky.team` still resolved forward to a DID whose current DID document and profile claimed `why.bsky.world`. A forward-only check would have admitted a stale team handle.

A bidirectionally valid `bsky.team` handle proves current authorization by the domain owner. It does not by itself prove an employment relationship.

## Implications

- Pin Skywatch by DID and the exact `bluesky-elder` value; never infer the label from profile text.
- Use direct `api.bsky.app` and require its labeler-confirmation response header.
- Treat labeler omission, expiry, negation, identity ambiguity, and lookup failure as fail-closed states.
- Re-resolve eligibility for each invocation rather than trusting an old observed handle.
- Require bidirectional DID/handle agreement for `bsky.team`.
