# Hosted PDS account setup

**Date:** 2026-08-11
**TL;DR:** For a time-sensitive Context Bot demonstration, create the account through Bluesky's
`bsky.social` service and then bind `getcontext.bot` as its handle with the `_atproto` TXT record.
The custom handle is independent of the PDS and can move with the account later.

## Context

The operator registered `getcontext.bot` and needed a hosted AT Protocol account within an hour.
The decision was whether to use Bluesky's hosted PDS service, Blacksky, or another provider while
retaining a custom domain handle and avoiding a self-hosted PDS.

## Findings

Bluesky signup is currently open without a waitlist or invite. Bluesky's current custom-handle
guidance explicitly tells users to create a placeholder `.bsky.social` account first and then
change it to the domain they own:

- <https://blueskyweb.zendesk.com/hc/en-us/articles/21885229414285-How-to-join-the-waitlist>
- <https://blueskyweb.zendesk.com/hc/en-us/articles/44878051792269>
- <https://bsky.social/about/blog/4-28-2023-domain-handle-tutorial>

For `getcontext.bot`, the DNS proof is a TXT record at `_atproto.getcontext.bot` whose value is
`did=did:plc:<the account DID>`. In Namecheap's host field this is normally entered as
`_atproto`, because Namecheap appends the zone name. The Bluesky handle flow supplies the exact DID
and updates the account side of the identity binding after DNS verification. The DID is public.

The custom domain is a handle, not a PDS location and not a second alias. Bluesky continues to host
the repository even though the visible handle is `getcontext.bot`. Bluesky also reserves the most
recent `.bsky.social` handle after the switch, and old mentions continue to identify the account by
DID.

Bluesky's user-facing hosted service is `bsky.social`, though it operates multiple PDS instances
behind an entryway. When configuring Context Bot, resolve the account's DID document and use its
`#atproto_pds` service endpoint when a concrete PDS origin is required; do not infer the PDS URL
from the custom handle.

Blacksky supports custom domain handles. Its `blacksky.app` PDS is reserved for Blacksky community
members, while `myatproto.social` and `cryptoanarchy.network` are open alternatives on the same
infrastructure. These are valid choices for governance or hosting-policy reasons, but add a custom
hosting-provider login path and provide no speed advantage for this demonstration:

- <https://docs.blacksky.community/migrating-to-blacksky-pds-complete-guide>
- <https://docs.blacksky.community/list-of-our-services>

Bluesky's bot guidance welcomes automated accounts, recommends the `bot` profile self-label, and
says interaction bots should act only when tagged. That matches Context Bot's direct-mention-only
scope. Use an app password rather than the account password for the deployed application:

- <https://docs.bsky.app/docs/starter-templates/bots>
- <https://blueskyweb.zendesk.com/hc/en-us/articles/19002493054861-Miscellaneous>

## Implications

- Use `bsky.social` for the initial hosted account and demonstration.
- Create and verify the account with an existing reachable email address before changing its
  handle.
- Add `_atproto` as a TXT host with the DID value shown by Bluesky, use a short DNS TTL, and verify
  public resolution before retrying the handle change.
- Set the profile's `bot` self-label and explain that replies occur only after a direct mention.
- Generate a dedicated app password for Context Bot and never store or deploy the main password.
- Record the DID and resolve the actual PDS service endpoint for `BOT_DID` and `BOT_PDS_URL`.
- A later PDS migration can preserve the DID, custom handle, and social graph; it is not necessary
  to choose a long-term alternative host before the demonstration.
