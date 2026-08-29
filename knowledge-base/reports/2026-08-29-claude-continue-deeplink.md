# Claude continue deep-link on Standard.site full-response pages

**Date:** 2026-08-29
**TL;DR:** New full-response documents include a `https://claude.ai/new?q=` markdown
link. The encoded starter names this document's Standard Reader URL and asks Claude
to fetch it as prior research, then wait. Existing PDS records are not rewritten.

## Why

There is no API that can inject a Messages-API transcript into a reader's
claude.ai history. A cold reader on Standard Reader can still continue the
conversation if we hand them a prefilled new-chat URL.

## What ships

1. After the Asked block and before `# Research Analysis`, new documents render
   `[Continue this conversation in Claude](https://claude.ai/new?q=...)`.
2. `q=` is a URL-encoded starter that includes
   `https://standard-reader.app/a/{did}/{rkey}` for this document. The rkey is
   allocated before `putRecord`, so the published markdown can name its own URL.
3. The starter does not copy `full_response` or `CONTEXT_BOT_SYSTEM_V5` into the
   query string. It does not use `claude://` or the unofficial `attachment=`
   parameter.

`q=` only prefills. The reader must be logged in to Claude and press enter.
Prefill is unofficial and may show an untrusted-prompt warning.

## Not shipped

Existing Standard.site documents stay as published. `add_post_ref/4` still only
adds `bskyPostRef`. There is no transcript injection, no rewrite job, and no
claim of deterministic Claude replay.
