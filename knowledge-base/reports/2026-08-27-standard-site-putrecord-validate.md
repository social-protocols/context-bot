# Standard.site putRecord validate:true create failure

**Date:** 2026-08-27
**TL;DR:** Fly invocations 6 and 7 stored `full_response` but left
`standard_site_document_uri` empty because `ReqClient.put_record/4` sent
`validate: true` for unknown `site.standard.*` lexicons, the PDS rejected the
write, and ResearchWorker swallowed that error with no log line.

## Context

Public `getRecord` of
`at://did:plc:anbhmngzs3exwbq47xxzogk4/site.standard.publication/context-bot`
was RecordNotFound. Compact Bluesky replies therefore had no `(full response)`
facet, and the invocations dashboard Full Response column rendered an em dash.
PR #51 had already pinned `createdAt`; this remaining failure is create, not
the old full-response drop.

## Findings

- `com.atproto.repo.putRecord` `validate: true` requires a known lexicon.
  Hosted PDS implementations do not resolve `site.standard.publication` or
  `site.standard.document`, so the write fails closed.
- The same client still sends `validate: true` for `app.bsky.feed.post`.
- `ResearchWorker.create_standard_site_document/5` treated any publication or
  document error as `{nil, nil}` with comments "don't block the reply" and no
  Logger call, so Fly logs only showed the later Bluesky publication.
- Freeze only attaches a reader URL when document create returns one, so the
  compact reply did not pretend a link existed. The missing operator-visible
  failure was the bug.

## Implications

Skip remote lexicon validation for `site.standard.*` writes (`validate: false`).
Keep requiring it for known app lexicons. Log status, collection, and the
ATProto error name/message, and persist that detail on the invocation while
still queueing the compact Bluesky reply.
