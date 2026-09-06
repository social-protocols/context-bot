# Surgical rollback of the getcontext.bot `/r/` writeup mirror

**TL;DR:** Public `GET /r/{id}` no longer serves full writeups. New Bluesky
`(full response)` facets and the invocations dashboard again use
`Document.reader_url_from_uri/1` (`https://standard-reader.app/a/{did}/{rkey}`).
`ReaderIndex` and the `reader_ready_*` cache stay for follower-card deferral.

## Why not `git revert` of `238d704`

#131 (`238d704`) added both the public mirror and the Standard Reader index
probe. #139 (`8bcf6ac`) depends on `ReaderIndex`, `reader_ready_at` /
`reader_checked_at`, and `Store.record_reader_index/3` to wait before posting
the follower write-up card. A whole-squash revert would break that path.

## Removed

- `ContextBot.StandardSite.Mirror`, `FullResponseController`, `MarkdownHTML`
- router `GET /r/:id`
- Bluesky / dashboard / homepage links that treated `/r/` as the published URL
- Mirror-only helpers `PromptDocument.research_ref/1` and `structure_ref/1`

## Kept

- `ReaderIndex.check/1` (`app.standard-reader.getDocument`)
- invocation `reader_ready_at` / `reader_checked_at` and the existing
  additive migration (no destructive column drop)
- `Store.record_reader_index/3` and `ReaderReady.ensure/2`, including the
  60s negative TTL #140 moved onto `ReaderReady` (no longer shared with a
  public `/r/` mirror)
- #139 follower deferral: card URL remains the Standard Reader URL

## Accepted leftover

Already-published Bluesky posts that linked `https://getcontext.bot/r/...`
no longer 404: `GET /r/:id` is a legacy 301 to Standard Reader. It still
does not serve writeups. See
[2026-09-06-legacy-r-redirect.md](2026-09-06-legacy-r-redirect.md).
