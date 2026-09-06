# Legacy `/r/` redirect to Standard Reader

**TL;DR:** `GET /r/{id}` is a thin 302 to the invocation’s Standard Reader
URL. New Bluesky posts still link to Reader directly. AppView can lag
in-place PDS rewrites and keep serving old CIDs that contain `/r/` links.

## Why

#142 removed the getcontext.bot writeup mirror. Published Bluesky part-2
(and some follower) records for invs 34–42 were rewritten on the bot PDS
to Standard Reader URLs, and sqlite matches the PDS. `public.api.bsky.app`
can still serve the old CIDs, so clients show `https://getcontext.bot/r/{id}`
and those clicks 404.

## What this is

- Lookup by invocation id, or by `standard_site_document_rkey` when the
  path is not a positive integer
- 302 to `Document.reader_url_from_uri/1` when that URI is present
- 404 with a short message when the row or Reader URL is missing
- No sqlite writeup page, Mirror module, or MarkdownHTML

## What this is not

New `(full response)` facets and follower cards keep using the Standard
Reader URL. Do not point new posts at `/r/`.
