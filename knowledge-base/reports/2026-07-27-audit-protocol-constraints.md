# Audit Protocol Constraints

**Date:** 2026-07-27
**Updated:** 2026-07-28
**TL;DR:** Strict schema output would require a separate call after cited Anthropic research, so the MVP instead asks the research response for a delimited reply and conditionally repairs only invalid candidates. ATProto CIDs establish content identity before publication, but only PDS inclusion authenticates repository state; IPFS adds no durability without operated or paid pins.

## Context

The Context Bot MVP needs to capture a complete Claude research transcript, construct final ATProto records locally, synchronize them asynchronously, and decide whether large audit artifacts justify IPFS.

## Investigation

The design review checked current primary documentation for:

- Anthropic model/tool versions, citations, structured outputs, prompt caching, server-tool continuations, and response inclusion;
- ATProto repository, record CID, blob lifecycle, Lexicon, strong-reference, notification, and thread-view behavior;
- IPFS content addressing, persistence, pinning, gateways, and privacy;
- the local record-first synchronization pattern in `atproto-community-notes`.

The approved design is recorded in `docs/superpowers/specs/2026-07-27-context-bot-mvp-design.md`.

## Findings

### Anthropic normally needs one invocation for this MVP

Citation-enabled web search cannot be combined with strict JSON Schema output. The MVP avoids needing a schema: ask the `claude-sonnet-5` research invocation with `web_search_20260318` and `web_fetch_20260318` to end with a delimited, budgeted Bluesky-reply candidate. Make one additional length-repair invocation only when that candidate is missing, malformed, or over budget. Preserve every response as an authoritative provider transcript. Sonnet 5 also rejects non-default temperature, `top_p`, and `top_k`, so leave them unset.

Sources: [structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [citations](https://platform.claude.com/docs/en/build-with-claude/citations), [Sonnet 5 behavior](https://platform.claude.com/docs/en/about-claude/models/whats-new-sonnet-5).

### Length repair should reuse the prompt cache

Anthropic automatic prompt caching matches the prefix in tools, system, then messages order. Research continuations and the optional repair request should therefore keep cache-affecting settings byte-identical, append the complete prior assistant content verbatim, and add only the final repair instruction. The repair request keeps the web tools configured for cache eligibility but instructs Claude not to use them; unexpected tool use invalidates the repair. Record cache-read, cache-creation, and per-TTL usage fields. A cache miss affects only cost and latency, never correctness.

Sources: [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [tool use with prompt caching](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-use-with-prompt-caching).

### Local CIDs are identity, not repository authentication

Canonical DAG-CBOR and raw blob CIDs can be calculated before PDS publication, enabling a durable intended-object store in SQLite. Before synchronization, those objects are content-addressed staging objects rather than authenticated members of an ATProto repository. PDS convergence includes them in signed repository state at a point in time; ATProto does not promise permanent append-only record history or continued availability.

Sources: [repository](https://atproto.com/specs/repository), [blobs](https://atproto.com/specs/blob), [data validation](https://atproto.com/guides/data-validation).

### IPFS is not durability by itself

IPFS is a protocol, not a storage provider. Durable availability requires controlled nodes or pinning providers plus monitored gateways. ATProto already supplies content-addressed blobs and a signed discovery layer, so IPFS should be deferred until measured PDS size/quota pressure or an explicit independent-availability requirement justifies a hybrid.

Sources: [what IPFS is](https://docs.ipfs.tech/concepts/what-is-ipfs/), [persistence and pinning](https://docs.ipfs.tech/concepts/persistence/), [privacy](https://docs.ipfs.tech/concepts/privacy-and-encryption/).

## Implications

- Model calls, records, tests, and audit UI must represent one primary research invocation plus at most one conditional length-repair invocation.
- The repair request must preserve the research request's cache prefix exactly and remain correct when the cache misses.
- Synchronization must verify the remote record CID, and the viewer must distinguish intended local state from observed PDS state.
- Published audit pages need a PDS rehydration path so synchronized runs survive local cache/database loss.
- Blob state must distinguish temporary upload from durable record reference.
- Do not add IPFS to the MVP publication or recovery path.
