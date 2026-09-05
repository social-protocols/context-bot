# Reply gate and compact_reply framing

**TL;DR:** Research `CONTEXT_BOT_SYSTEM_V12` and structure `CONTEXT_BOT_STRUCTURE_V7`
publish a Bluesky reply only when the invoking mention has an obvious question or
request aimed at Context Bot. Claim-only counterarguments are `no_reply` with an
empty `CONTEXT_BOT_DRAFT`. `compact_reply` is worded as a reply to that invoking
post. Do not recover or rewrite inv 35 or 37.

## Why

Inv 35 (diogeneslamp shape) mentioned the bot and asserted two checkable claims
(zoonosis studies; FBI/GenBank) without asking the bot anything. The bot
fact-checked the dump and published a compact that opened “Both claims check out
substantially…”. In a busy thread that floating referent was confusing. Under
the 2026-09-05 product rule it should have been no reply.

Inv 37 (empty-draft short-circuit) is already covered by #137. This change does
not reopen that path or recover either invocation.

## Gate

Reply only when the invoking mention has an obvious question or request aimed at
this bot. No reply for praise, third-party suggestions, meta comments with no
question, or a counterargument / debate move that asserts checkable claims but
does not ask the bot anything. Do not fact-check a claim-dump just because the
claims are verifiable. Research leaves title and `compact_reply` blank inside
`CONTEXT_BOT_DRAFT`; Runner still skips the paid structure call (#137).

## Compact framing

`compact_reply` is the published Bluesky body. Write it as a reply to the
invoking mention. Address that post’s question or request in the opening so a
reader can tell what is being answered. Do not open with a floating referent
such as “Both claims check out” or “That claim is true” without tying it to
what the invoker asked or requested.

Existing “identify every distinct question” / “open by directly answering each
asked question” language stays as-is. This change does not add enumerate-claims
wording.

## What stays the same

Empty-draft no_reply still short-circuits structure. Already-published Bluesky
posts are not rewritten. Inv 35 and 37 are not recovered or reenqueued from
this PR.
