# getcontext.bot full-response mirror

**TL;DR:** New `(full response)` links point at `https://getcontext.bot/r/{id}`.
That page serves the stored writeup immediately and 302s to Standard Reader
only after `app.standard-reader.getDocument` says the document is indexed.

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
