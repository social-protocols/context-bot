# Disable follower-feed auto quote posts

**TL;DR:** `FOLLOWER_POSTS_ENABLED` defaults to false. `@getcontext.bot` was
labeled Spam (Account) by `@moderation.bsky.app` after follower-feed auto
quote+card posts (#134). Thread replies are unchanged. Historical follower
posts are not deleted.

## Gate

`ContextBot.Settings` loads `FOLLOWER_POSTS_ENABLED` as a boolean defaulting
to false. `FollowerPost.eligible?/1` returns false when the gate is off, so
`ReplyWorker.finish_publication` skips follower `putRecord` and does not
enqueue backlog. `FollowerPostWorker.perform` also returns `:ok` without
`putRecord` for both per-invocation jobs and the minute cron reconsider.

Set `FOLLOWER_POSTS_ENABLED=true` to re-enable later without a code revert.
Do not delete stored `follower_post_*` fields in this change.
