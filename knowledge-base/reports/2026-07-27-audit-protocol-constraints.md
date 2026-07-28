# Audit Protocol Constraints

**Date:** 2026-07-27
**TL;DR:** Anthropic's cited research and strict schema output require separate calls. ATProto CIDs establish content identity before publication, but only PDS inclusion authenticates repository state; IPFS adds no durability without operated or paid pins.

## Context

The Context Bot MVP needs to capture a complete Claude research transcript, construct final ATProto records locally, synchronize them asynchronously, and decide whether large audit artifacts justify IPFS.

## Investigation

The design review checked current primary documentation for:

- Anthropic model/tool versions, citations, structured outputs, server-tool continuations, and response inclusion;
- ATProto repository, record CID, blob lifecycle, Lexicon, strong-reference, notification, and thread-view behavior;
- IPFS content addressing, persistence, pinning, gateways, and privacy;
- the local record-first synchronization pattern in `atproto-community-notes`.

The approved design is recorded in `docs/superpowers/specs/2026-07-27-context-bot-mvp-design.md`.

## Findings

### Anthropic needs two invocations

Citation-enabled web search cannot be combined with strict JSON Schema output. Use a first `claude-sonnet-5` research invocation with `web_search_20260318` and `web_fetch_20260318`, then a second tool-free invocation that structures a deterministic evidence envelope. Preserve the first response as the authoritative provider transcript. Sonnet 5 also rejects non-default temperature, `top_p`, and `top_k`, so leave them unset.

Sources: [structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [citations](https://platform.claude.com/docs/en/build-with-claude/citations), [Sonnet 5 behavior](https://platform.claude.com/docs/en/about-claude/models/whats-new-sonnet-5).

### Local CIDs are identity, not repository authentication

Canonical DAG-CBOR and raw blob CIDs can be calculated before PDS publication, enabling a durable intended-object store in SQLite. Before synchronization, those objects are content-addressed staging objects rather than authenticated members of an ATProto repository. PDS convergence includes them in signed repository state at a point in time; ATProto does not promise permanent append-only record history or continued availability.

Sources: [repository](https://atproto.com/specs/repository), [blobs](https://atproto.com/specs/blob), [data validation](https://atproto.com/guides/data-validation).

### IPFS is not durability by itself

IPFS is a protocol, not a storage provider. Durable availability requires controlled nodes or pinning providers plus monitored gateways. ATProto already supplies content-addressed blobs and a signed discovery layer, so IPFS should be deferred until measured PDS size/quota pressure or an explicit independent-availability requirement justifies a hybrid.

Sources: [what IPFS is](https://docs.ipfs.tech/concepts/what-is-ipfs/), [persistence and pinning](https://docs.ipfs.tech/concepts/persistence/), [privacy](https://docs.ipfs.tech/concepts/privacy-and-encryption/).

## Implications

- Model calls, records, tests, and audit UI must represent research and structuring as separate invocations.
- Synchronization must verify the remote record CID, and the viewer must distinguish intended local state from observed PDS state.
- Published audit pages need a PDS rehydration path so synchronized runs survive local cache/database loss.
- Blob state must distinguish temporary upload from durable record reference.
- Do not add IPFS to the MVP publication or recovery path.
