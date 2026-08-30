# Context Bot

Mention [@getcontext.bot](https://bsky.app/profile/getcontext.bot) on a Bluesky post and ask it a question. It does the research and produces a brief response.

## What it is

A quick way to invoke an AI agent in a Bluesky thread. Use it for research, fact checking or clarification about any post.

[@getcontext.bot](https://bsky.app/profile/getcontext.bot) is inspired by @grok on X, but it uses Claude instead.

## How to use

Anyone can mention it; it joins a thread when invited. Ask a concrete question, for example:

- “Is this claim true?”
- “What important context is missing?”
- “Can you find the original source?”

## Example

**The Story on the Yosemite Land Deal**

Asked:

> [@getcontext.bot](https://bsky.app/profile/getcontext.bot) What's the story here? How big is the parcel? Why does the developer want it? What would the Park Service get in return? Is there a legitimate reason for the NPS to consider it?

Reply:

> Per NOTUS: since spring 2025, NPS staff have been pressured by Interior leadership to cede a ~0.25-mile strip inside Yosemite to Kingsbarn Realty Capital (CEO Jeff Pori), for a road linking its 83-acre plot to a park road near sequoias.

[Full writeup](https://standard-reader.app/a/did:plc:anbhmngzs3exwbq47xxzogk4/3mu67jhxqnv2b) · [Bluesky reply](https://bsky.app/profile/getcontext.bot/post/3mu67jhxqnv2c)

## Why it works

- **Invited, not proactive.** Anyone can mention it; it joins a thread when invited.
- **Research with Sources.** It uses Claude Sonnet with web search and citations enabled.
- **Transparent.** The full prompt and reply, including cited sources, are stored as atproto records.

Daily mention limits apply.

---

See on [github](https://github.com/social-protocols/context-bot/).

A [Social Protocols](https://social-protocols.org) project.
