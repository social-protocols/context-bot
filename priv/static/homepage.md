# Context Bot

Mention [@getcontext.bot](https://bsky.app/profile/getcontext.bot) on a Bluesky post and ask it a question. It does the research and produces a brief response.

## What it is

A quick way to invoke an AI agent in a Bluesky thread. Use it for research, fact checking or clarification about any post.

@getcontext-bot is inspired by @grok on X, but it uses Claude instead.

## Why it works

- **Invite Only.** It only joints a thread when invited.
- **Research with Sources.** It uses Claude Sonnet with web search and citations enabled. 
- **Transparent.** The full prompt and reply, including cited soures, are stored as atproto records.

## Limits

Anyone may mention [@getcontext.bot](https://bsky.app/profile/getcontext.bot).

- **Operator** (Jonathan): no daily or hourly actor cap.
- **Bluesky elders** (Skywatch `bluesky-elder`) and verified `bsky.team` / `*.bsky.team`: 5 invocations per rolling day.
- **Everyone else:** 1 invocation per rolling day.

A shared hourly and daily cap, and a pending-work limit, can still delay a reply.

Research is paid from a shared operator Anthropic budget (currently $20 per UTC day). When that budget is spent, the bot posts a short notice instead of researching. Later, people will be able to enter their own funding keys.

---

See on [github](https://github.com/social-protocols/context-bot/).

A [Social Protocols](https://social-protocols.org) project. 