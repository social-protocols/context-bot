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
- `Store.record_reader_index/3` and `ReaderReady.ensure/2`
- #139 follower deferral: card URL remains the Standard Reader URL

## Accepted leftover

Already-published Bluesky posts that linked `https://getcontext.bot/r/...`
will 404. Those URLs are not rewritten and are not served as writeups.
