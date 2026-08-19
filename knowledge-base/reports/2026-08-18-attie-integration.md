# Attie Quests and Context Bot

**Date:** 2026-08-18
**TL;DR:** Attie Quests packages Atmosphere-native discovery into a closed-beta research product, but no supported programmatic integration is publicly documented. Context Bot should not depend on Attie now; if Atmosphere-wide evidence becomes valuable, add it behind a provider-neutral evidence interface and evaluate Attie only after it publishes a stable contract.

## Context

Bluesky announced Quests for Attie as an interactive research and exploration tool for the Atmosphere. The question was whether this is meaningfully different from asking a general AI chatbot to research something and whether Context Bot should integrate with it.

## Investigation

Reviewed the following public sources on 2026-08-18:

- Jay Graber's announcement, [Introducing Quests](https://theliquidfrontier.leaflet.pub/3mrddkznuuc2g), which describes trending-topic research, influential-account discovery, personalized daily briefings, a closed beta, and an opt-in interface.
- Jay Graber's original [Attie announcement](https://theliquidfrontier.leaflet.pub/3mi5pwkoqx22g), which positions Attie as a separate, agentic social app and custom-feed builder over the Atmosphere's open data layer.
- [TechCrunch's launch coverage](https://techcrunch.com/2026/07/24/blueskys-ai-assistant-attie-expands-into-an-open-social-research-tool/), which confirms that Quests is an open-ended research feature spanning Bluesky and other AT Protocol applications.
- Attie's public login page and web-visible materials. No supported public API, SDK, Quest request/response schema, service account flow, pricing contract, or availability guarantee was found. This is a negative finding about currently published material, not a claim that Bluesky has no private interface.
- The [AT Protocol specification](https://atproto.com/specs/atp), which distinguishes open repository data from application-specific aggregations such as search supplied by AppViews.
- Anthropic's [web-search tool documentation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool), which confirms that a general Claude integration can already conduct iterative, current web research with citations when given tools.

The existing repository implementation was compared at these boundaries:

- `lib/context_bot/thread/canonicalizer.ex` intentionally supplies only the invocation and its ancestors.
- `lib/context_bot/research/request.ex` already gives Claude bounded web search and fetch tools, asks for primary sources, treats thread content as untrusted, and requires a reply of at most 300 grapheme clusters.
- `lib/context_bot/research/runner.ex` durably reserves and settles provider cost, retains bounded response envelopes, handles continuations, and fails closed on ambiguous sends.
- `docs/superpowers/specs/2026-07-28-context-bot-poc-design.md` explicitly excludes firehose/Jetstream ingestion, descendants, proactive ranking, and unsolicited replies from the POC.

## Findings

### Attie is differentiated by data and product context, not by prompting alone

A prompt controls an agent's objective but cannot grant missing tools or data. A generic chatbot without live ATProto access sees only what the user pastes and whatever a general web index exposes. Attie is designed around the Atmosphere itself: it can inspect activity across an ATProto-oriented corpus, work with social/account context, and turn broad questions into social-network exploration or recurring briefings.

That is a meaningful advantage for questions such as "what is gaining momentum here?" or "which accounts shape this community?" It is less inherently useful for verifying an external factual claim, where primary web sources are usually stronger evidence than popularity or repetition in social posts.

A tool-equipped general agent can reproduce the agentic part. Context Bot already does this for the web: Claude decides when to search and fetch, may continue a tool-using turn, and synthesizes the result. Giving that agent a bounded ATProto search or graph tool would narrow much of the remaining capability gap without making Attie a dependency.

### Attie and Context Bot serve different interaction models

Attie is an opt-in, interactive exploration product. Context Bot is a direct-mention service that answers at the point of confusion and publishes one short reply into the public conversation. The latter creates shared thread context for every reader; the former supports private, broader, iterative exploration and personalization.

The overlap is the phrase "make sense of social information," not the actual contract. Context Bot's durable workflow, one-reply guarantee, cost ledger, ancestor-only boundary, and fail-closed publication logic remain product-specific value that a normal Attie session does not replace.

### A direct integration is premature

No supported machine contract is publicly documented, and Quests remains closed beta. Calling an observed private web endpoint would create an unstable dependency, couple the bot to interactive user authentication, and weaken the bot's current ability to bound cost, retain provider evidence, reconcile ambiguity, and test deterministically.

Attie's output should also not automatically be treated as verified evidence. Its public announcement does not specify Quest citation completeness, corpus coverage, ranking definitions, time windows, reproducibility, retention, or failure semantics. "Influential" and "trending" are AppView interpretations, not protocol-level facts.

## Implications

- Do not integrate Context Bot with Attie during the POC.
- Treat Attie as adjacent product validation: users want help interpreting the Atmosphere, but Context Bot's distinct wedge is an invoked, public, concise answer in situ.
- If real invocations reveal a material need for Atmosphere-wide evidence, first design a narrow, read-only, provider-neutral evidence interface. Candidate implementations could use reviewed public AppView search/graph endpoints or a separately operated index.
- Reconsider Attie only when Bluesky publishes a stable machine interface with authentication, source/evidence semantics, quotas/pricing, retention, error behavior, and a compatibility policy.
- Evaluate any future provider by replaying a fixed corpus of questions and measuring source coverage, factual correctness, latency, cost, and whether the public 300-character answer improves.
