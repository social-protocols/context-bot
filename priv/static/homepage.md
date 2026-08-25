# Context Bot

Mention @getcontext.bot on a Bluesky post. It replies with context, not a vibe check.

## What it is

A small social protocol for when someone in the thread actually wants the receipts. You invoke it. It reads the public thread. It writes a reply you can argue with.

## Philosophy

Attention is already a protocol (feeds, ranking, quotes). Most of it is ambient and opaque. Context Bot is the opposite: opt-in, bounded, and inspectable. It is not a moderator and not a global truth oracle. It is a tool a participant can pull into a conversation.

## Why it works

- **Invoked, not ambient.** It does not roam the firehose scoring posts.
- **Public evidence.** Text, captions, quotes, linked reporting. It does not pretend to watch video frames.
- **Bounded.** Bluesky's 300-grapheme cap is real. If the answer still will not fit after one repair, it splits into two posts so the thread stays in order.
- **Fail closed in public.** A broken model output does not become a failure apology on the timeline.

## Transparency (the ATProto-nerd part)

The bot is a DID. Replies are ordinary app.bsky.feed.post records with mention facets and strong refs. The long form belongs in a site.standard.document on the same PDS, with getcontext.bot as the publication domain (see https://standard.site). A compact Bluesky reply should point at that document, not try to be the essay. Readers can fetch the record like any other ATProto object. Social Protocols publishes open algorithms; this bot should be as inspectable as the rest.

## How to use

On Bluesky, autocomplete @getcontext.bot (the dotted handle). Ask a concrete question about the post you are under, not "is this true?"

---

A Social Protocols project. https://social-protocols.org
