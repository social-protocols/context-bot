# Contributing to Context Bot

Thank you for your interest in contributing to Context Bot! This document provides guidelines for contributing to the project.

## Development Environment

Context Bot uses **Devbox** and **direnv** for reproducible development environments. Do not use globally installed tools.

### Prerequisites

- [Devbox](https://www.jetify.com/devbox/docs/installing_devbox/)
- [direnv](https://direnv.net/docs/installation.html), hooked into your shell
- Docker Desktop or another Docker daemon (only for local image builds)

### Initial Setup

```bash
# Clone the repository
git clone https://github.com/social-protocols/context-bot.git
cd context-bot

# Allow direnv (required once per checkout or worktree)
direnv allow

# Copy environment template
cp .env.example .env

# Load environment variables
set -a
source .env
set +a

# Install dependencies and setup database
just setup

# Start the development server
just dev
```

The development server starts with `BOT_ENABLED=false` by default, so it will not contact Bluesky or Anthropic.

### Available Commands

| Command | Purpose |
|---------|---------|
| `just` or `just help` | List all available commands |
| `just setup` | Install dependencies and prepare SQLite |
| `just dev` | Start Phoenix development server |
| `just test [path]` | Run tests (all or specific path) |
| `just format` | Format Elixir and shell code |
| `just format-check` | Verify code formatting |
| `just lint` | Run Credo and ShellCheck |
| `just typecheck` | Run Dialyzer type checker |
| `just check` | Run complete quality gate (format, lint, test, typecheck) |

## Making Changes

### Workflow

1. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the project's architecture and constraints (see AGENTS.md)

3. **Run the quality gate** before committing:
   ```bash
   just check
   ```
   This runs:
   - Format checking
   - Compilation with warnings as errors
   - Linting (Credo + ShellCheck)
   - Full test suite
   - Type checking (Dialyzer)

4. **Commit your changes** with a clear, descriptive message:
   ```bash
   git add .
   git commit -m "feat: add helpful feature description"
   ```

5. **Push your branch** and create a pull request:
   ```bash
   git push -u origin feature/your-feature-name
   ```

### Commit Message Guidelines

Use conventional commit format:
- `feat:` for new features
- `fix:` for bug fixes
- `docs:` for documentation changes
- `test:` for test additions or modifications
- `chore:` for maintenance tasks
- `refactor:` for code refactoring

### Code Style

- **Elixir**: Follow the project's formatter configuration (`.formatter.exs`)
- **Shell scripts**: Use `shfmt` formatting (applied by `just format`)
- **Compilation**: Code must compile without warnings
- **Linting**: Must pass Credo and ShellCheck
- **Type checking**: Must pass Dialyzer

## Testing

### Running Tests

```bash
# Run all tests
just test

# Run a specific test file
just test test/context_bot/eligibility_test.exs

# Run tests with coverage
mix test --cover
```

### Writing Tests

- Write behavior-first ExUnit tests for application features
- Write shell tests for secret-loading behavior
- Watch the test fail first, then make it pass
- Test files should mirror the structure of `lib/`

## Project Constraints

Please review [AGENTS.md](AGENTS.md) before making changes. Key constraints:

### POC Scope

- Direct mentions only (no descendants, no proactive moderation)
- No UI, no audit pages, no IPFS (intentionally deferred to MVP)
- Do not add deferred features without an approved design

### Architecture Invariants

- Ingest only direct mentions, never call notification `updateSeen`
- Fetch invocation + ancestors only (`depth=0`), never descendants
- Fail closed on eligibility (verified handles, labels, or operator allowlist)
- Reserve budget before Anthropic work, mark attempts as sent before POST
- Preserve complete provider responses within configured bounds
- One frozen reply per invocation (reconcile ambiguous writes, never allocate second rkey)

### External Requests

- Keep `APPVIEW_URL` pinned to reviewed public AppView origin
- Keep timeouts, limits, and API versions runtime-configurable via `ContextBot.Settings`
- Malformed or out-of-range settings must fail startup

## Isolated Worktrees

For substantial feature work, use isolated worktrees:

```bash
git worktree add .worktrees/my-feature -b feature/my-feature main
cd .worktrees/my-feature
direnv allow
just setup
```

Each worktree maintains independent `deps/`, `_build/`, and `data/` directories.

## Pull Request Guidelines

- Keep PRs focused and single-purpose
- Include tests for new features and bug fixes
- Update documentation if behavior changes
- Ensure `just check` passes locally before pushing
- Fill out the PR template completely
- Reference any related issues
- GitHub Actions `Test & Quality Check` and `Type Check` run on the PR, not after merge to `main`. Merge with squash+fast-forward; `main` only deploys. Keep those two checks required in branch protection so untested code cannot merge.

## Questions?

- Check the [README](README.md) for usage and deployment documentation
- Review [AGENTS.md](AGENTS.md) for architecture and constraints
- See [knowledge-base/learnings.md](knowledge-base/learnings.md) for distilled facts
- Report vulnerabilities privately using [SECURITY.md](SECURITY.md); do not open a public issue for them
- Open an issue for questions or clarifications

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
