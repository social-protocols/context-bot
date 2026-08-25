# Bluesky Media Provider Boundaries

**Date:** 2026-08-25
**TL;DR:** The AppView thread response already identifies images and videos, but Context Bot's v1
canonicalizer silently discarded both. Anthropic Messages accepts static image blocks but not video,
so validated Bluesky CDN images can enter bounded research while videos require a deterministic
provider-free fallback until a separate video design is approved.

## Context

The first operator dry run targeted a Bluesky post containing an aurora video and asked whether it
was AI-generated. Claude returned a confident factual answer even though the canonical prompt
contained only post text. Inspection of the retained AppView response showed an
`app.bsky.embed.video#view`; inspection of `ContextBot.Thread.Canonicalizer` showed that the catch-all
embed clause discarded media.

The task was to fix that unsafe omission for videos, support images now, and identify a credible
future direction for video understanding.

## Investigation

- `lib/context_bot/thread/canonicalizer.ex` retained the AppView `embed` value on each available post
  but rendered only external links and quoted-post URIs. All other embed unions became an empty list.
- `test/fixtures/atproto/thread_ancestors.json` already contained an image view whose alt text and CDN
  URL were intentionally asserted absent, confirming that media omission was part of canonical v1.
- `lib/context_bot/research/request.ex` sent the entire canonical transcript as one string user
  message, while Anthropic's vision API accepts ordered image content blocks using base64, URL, or
  file sources.
- Anthropic's official vision documentation lists JPEG, PNG, GIF, and WebP input. It does not expose
  a video content block, and animated GIF analysis uses only the first frame:
  <https://platform.claude.com/docs/en/build-with-claude/vision>.
- xAI's X Search documentation exposes `enable_image_understanding` and
  `enable_video_understanding`, with video understanding available for X Search rather than general
  web search: <https://docs.x.ai/developers/tools/x-search>. The documentation does not describe its
  frame sampling, audio, transcription, storage, or safety pipeline, and it operates on X rather
  than Bluesky media.

## Findings

1. The safe immediate boundary is static images only. Context Bot can send the full-size URL from a
   trusted AppView response as an Anthropic URL image block without downloading image bytes or
   expanding SQLite storage.
2. AppView media still needs validation. Accept only `https` URLs on the exact `cdn.bsky.app` host
   with the reviewed full-size path, bounded URL/alt sizes, no userinfo, fragment, query, or
   non-default port.
3. Images must be ordered root-to-invocation and tied to numbered transcript markers so Claude can
   associate each block with its post. The captured chain remains ancestor-only.
4. Image appearance is not reliable synthetic-origin evidence. The prompt must separate direct
   observation from caption/alt claims, research provenance when material, and state uncertainty.
5. A video must never degrade into a text-only model answer. Until video inputs are durably captured,
   any video in the captured chain should bypass Anthropic and use one deterministic capability
   answer through the normal exactly-once reply path.
6. xAI provides a product precedent but not a reusable Bluesky implementation. Future work must
   compare a video-capable provider with a bounded local pipeline for origin-validated download,
   deterministic frame sampling, optional audio transcription, immutable request inputs, and strict
   byte/duration/time/storage/spend caps.

## Implications

- Keep canonical media structured and versioned instead of encoding URLs into prose and reparsing
  the prompt later.
- Persist the exact Anthropic content list before a request can escape, just as for text-only
  research, so retries never silently change image input.
- Do not store image bytes merely to add vision support; URL blocks preserve current storage bounds.
- Treat unsupported media as a local workflow decision with zero provider attempts and zero usage,
  while retaining reply freezing, publication fencing, and dry-run non-publication.
- Do not infer that xAI's X-only switch solves Bluesky video. Video support is a separate project
  with a wider network, media-processing, provider, and persistence threat model.
