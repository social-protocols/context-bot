# Security Policy

## Supported versions

This is an experimental proof of concept. Security fixes land on the `main`
branch of [social-protocols/context-bot](https://github.com/social-protocols/context-bot).
There are no older release lines.

## Reporting a vulnerability

Please report vulnerabilities **privately**. Do not open a public GitHub issue,
pull request, or discussion that includes exploit details or credentials.

1. Prefer a [GitHub private vulnerability report](https://github.com/social-protocols/context-bot/security/advisories/new).
2. If that form is unavailable, email [mail@social-protocols.org](mailto:mail@social-protocols.org)
   with the subject `context-bot security`.

Include enough information to reproduce the issue (affected URL or commit,
what you expected, what happened). We will acknowledge the report and follow
up as soon as we can.

**Do not paste** post bodies, provider bodies, Bitwarden payloads, app
passwords, API keys, session tokens, or Fly tokens into tickets, chat, or
public GitHub artifacts.

If you found a live credential in this repository or in logs, report it
privately and do not republish the value.

## Scope

In scope for this repository and the deployed `@getcontext.bot` service:

- Leaked credentials, tokens, or app passwords in git, logs, or GitHub Actions
- Authentication, session, or authorization bugs in the ATProto client
- Eligibility or admission bypass that lets an unintended actor spend budget
  or publish a reply
- Exposure of stored invocation, thread, or provider content through `/health`
  or other HTTP endpoints
- Paths that could publish more than one reply for an invocation, or publish
  from a `dry_run` invocation

Out of scope:

- The bot posting inaccurate or incomplete context
- Disagreement with the actor rate-limit tiers (`bsky.team`, Skywatch
  `bluesky-elder`, the operator DID allowlist, or the public daily cap)
- Bugs in Bluesky, Anthropic, Fly, or Bitwarden themselves

## Secrets in this project

Never commit `.env` files, Bitwarden payloads, or secret values. Runtime
secrets belong in Bitwarden and Fly (and `FLY_API_TOKEN` in GitHub Actions),
not in the tree. See the README for operator secret-loading behavior.

Reports that only describe a missing `SECURITY.md`, Dependabot setting, or
similar documentation gap can be public issues.
