# Cloud Agent Dockerfile for Context Bot
# Provides Elixir 1.20.2 + Erlang/OTP 28.5.0.3 for mix commands

FROM hexpm/elixir:1.20.2-erlang-28.5.0.3-debian-trixie-20260713-slim

# Install build tools and SQLite for native dependencies and testing
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    jq \
    libsqlite3-dev \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Mix and hex tools come with Elixir; Elixir is already on PATH
