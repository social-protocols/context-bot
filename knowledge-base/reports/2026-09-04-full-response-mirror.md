# getcontext.bot full-response mirror

**Superseded:** the public `/r/` writeup mirror was rolled back. New
`(full response)` links use the Standard Reader URL again. The index probe
and `reader_ready_*` cache remain for follower-card deferral. Restored
`GET /r/:id` is a **301** to Reader, not the historical 302-after-index
behavior below. See
[2026-09-05-rollback-full-response-mirror.md](2026-09-05-rollback-full-response-mirror.md)
and [2026-09-06-legacy-r-redirect.md](2026-09-06-legacy-r-redirect.md).

**Historical TL;DR (as shipped in #131):** New `(full response)` links pointed
at `https://getcontext.bot/r/{id}`. That page served the stored writeup
immediately and 302ed to Standard Reader only after
`app.standard-reader.getDocument` said the document was indexed.

## Why

Standard Reader indexes `site.standard.document` from the firehose. Until Tap
has the record, `https://standard-reader.app/a/{did}/{rkey}` is an empty SPA
shell (`<title>Article</title>`, generic OG, no body). Inv 31 was an example:
the PDS already had the markdown. There is no push API into Reader.

## Detection

Do not scrape the HTML shell. On 2026-09-04 the public AppView contract was:

| Probe | Meaning |
|---|---|
| `GET https://standard-reader.app/xrpc/app.standard-reader.getDocument?document={at-uri}` → 200, matching `uri`, `hasRenderableBody: true` | Indexed |
| HTTP 400 `InvalidRequest` / `Document not found` | Not indexed |
| Timeout, 5xx, malformed body, 200 without a renderable body | Ambiguous — stay on the mirror |

## Cache

- `reader_ready_at` latches a confirmed index hit. Later requests 302 without
  calling Reader.
- `reader_checked_at` is a 60s negative cache for misses and ambiguous probes.
- Redirects are **302**, not 301: the getcontext.bot URL is the durable
  Bluesky identifier, and a 301 would pin clients to Reader if the index
  later looks empty.

## What stays the same

PDS `site.standard.document` create, prompt documents, and Standard.site
publication are unchanged. Already-published Bluesky posts are not rewritten;
their document rkeys still resolve at `/r/{rkey}` from stored sqlite fields.
