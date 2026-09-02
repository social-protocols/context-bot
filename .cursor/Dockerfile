# Cursor cloud agent image. Tracks non-Beam packages from devbox.json so
# agents have the same commonly used tools; Elixir/OTP come from the hexpm
# tag instead of Nix.
#
# Non-Beam counterparts on PATH: just, flyctl, bitwarden-cli (bw),
# docker-client (docker), git, jq, curl, shellcheck, shfmt, flock,
# coreutils, sqlite-interactive (sqlite3).

FROM hexpm/elixir:1.20.2-erlang-28.5.0.3-debian-trixie-20260713-slim

# Distro packages plus build-essential for native mix deps.
# docker-cli is the docker-client analog (CLI only, no daemon).
# util-linux provides flock if the slim image omits it.
# coreutils is already on Debian.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    docker-cli \
    git \
    jq \
    libsqlite3-dev \
    shellcheck \
    shfmt \
    sqlite3 \
    unzip \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# just (static binary from just.systems)
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin

# flyctl: official installer into /usr/local so fly and flyctl are on PATH
# without $HOME/.fly PATH hacks.
RUN export FLYCTL_INSTALL=/usr/local && \
    curl --proto '=https' --tlsv1.2 -sSfL https://fly.io/install.sh | sh && \
    rm -rf /usr/local/tmp

# bitwarden-cli: official bw binary on PATH (not a login).
RUN curl --proto '=https' --tlsv1.2 -sSfL \
        "https://bitwarden.com/download/?app=cli&platform=linux" \
        -o /tmp/bw.zip && \
    unzip -o /tmp/bw.zip -d /tmp && \
    install -m 0755 /tmp/bw /usr/local/bin/bw && \
    rm -f /tmp/bw.zip /tmp/bw

# Confirm the Devbox-aligned tools are on PATH.
RUN command -v elixir && command -v erl && \
    command -v just && command -v fly && command -v flyctl && \
    command -v bw && command -v docker && \
    command -v git && command -v jq && command -v curl && \
    command -v shellcheck && command -v shfmt && \
    command -v flock && command -v sqlite3
