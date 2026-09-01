# Sandboxed OpenCode server with some additional tools and MCP servers

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# 1: Use a nice slim Debian-based image
# Pinned by digest (multi-arch manifest list). Refresh deliberately: query the
# new digest, update it here, and re-run the checksum verification flow.
#   curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/node:pull" \
#     | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' > /tmp/token
#   curl -fsSL -H "Authorization: Bearer $(cat /tmp/token)" \
#     -H "Accept: application/vnd.oci.image.index.v1+json" \
#     -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
#     -D - -o /dev/null "https://registry-1.docker.io/v2/library/node/manifests/24-trixie-slim" \
#     | grep -i docker-content-digest
FROM node:24-trixie-slim@sha256:50c3b2f6988dfc307b86e5301d69611af31f4789bdf232863b07d3b02fe55ae0

ARG USER_ID=1001
ARG GROUP_ID=1001
ARG DOCKER_GROUP=111
# Browser versions
ARG ENGRAM_VERSION
# SHA256 of the engram release tarball (fail-closed when empty)
ARG ENGRAM_SHA256
# Docker buildx CLI plugin (pinned; latest stable from github.com/docker/buildx/releases)
ARG BUILDX_VERSION
# SHA256 per architecture of the buildx plugin binary (fail-closed when empty)
ARG BUILDX_SHA256_AMD64
ARG BUILDX_SHA256_ARM64

# Default timezone, can be overridden
ENV TZ=Europe/Amsterdam

# Set some sane OpenCode and Openspec defaults
ENV DO_NOT_TRACK=1
ENV OPENSPEC_TELEMETRY=0
ENV OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS=36000000
ENV OPENCODE_CONFIG_DIR=/home/node/.config/opencode
ENV OPENCODE_DISABLE_AUTOUPDATE=true
# Enable websearch - see https://opencode.ai/docs/tools/#websearch
ENV OPENCODE_ENABLE_EXA=1

ENV DEBIAN_FRONTEND="noninteractive"

# Ensure that Chrome can run headless
ENV XDG_CONFIG_HOME=/home/node/.config
ENV XDG_CACHE_HOME=/home/node/.cache

# Ensure that both Playwright and agent-browser share the same browsers
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.agent-browser/browsers
ENV AGENT_BROWSER_EXECUTABLE_PATH=/opt/google/chrome/chrome
ENV PLAYWRIGHT_MCP_USER_DATA_DIR=./memory/playwright-mcp/

# Add Python package location to the path
ENV PATH="/opt/venv/bin:$PATH"

# 2: Install optional custom CA certificates into the system trust store
# (update-ca-certificates requires the .crt extension)
# Note: COPY silently adds nothing when no *.pem exists, so guard everything.
COPY *.pem /usr/local/share/ca-certificates/custom/
RUN set -eux; \
    d=/usr/local/share/ca-certificates/custom; \
    if [ -d "$d" ] && ls "$d"/*.pem > /dev/null 2>&1; then \
        for f in "$d"/*.pem; do mv -- "$f" "${f%.pem}.crt"; done; \
        update-ca-certificates; \
    fi; \
    rm -rf /usr/local/share/ca-certificates/custom

# 4: Install system packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bind9-dnsutils \
    ca-certificates \
    curl \
    docker-cli \
    docker.io \
    fd-find \
    file \
    fuse-overlayfs \
    git \
    iproute2 \
    iputils-ping \
    jq \
    libxml2-utils \
    lsof \
    make \
    netcat-openbsd \
    libcap2-bin \
    openssh-client \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    rootlesskit \
    shellcheck \
    slirp4netns \
    sshpass \
    tree \
    tzdata \
    uidmap \
    unzip \
    whois \
    xxd \
    yamllint \
    zip \
    zsh && \
    ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# 4b: Install the buildx CLI plugin (version- and checksum-pinned).
# Without it, 'docker build' inside the rootless DinD daemon falls back to the
# deprecated legacy builder (see https://docs.docker.com/go/buildx/). Once the
# plugin exists, Engine >= 23 auto-selects BuildKit through the default
# docker-driver: no further configuration is needed.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) expected="${BUILDX_SHA256_AMD64}" ;; \
        arm64) expected="${BUILDX_SHA256_ARM64}" ;; \
        *) echo "ERROR: no pinned checksum for architecture '$arch'" >&2; exit 1 ;; \
    esac; \
    if [ -z "$expected" ]; then \
        echo "ERROR: build-arg BUILDX_SHA256_${arch} is empty - the Makefile must pass it via --build-arg (stale checkout? re-sync Makefile + Dockerfile together)" >&2; \
        exit 1; \
    fi; \
    expected="$(printf '%s' "$expected" | tr -d '\r\n \t')"; \
    install -D -m 0755 /dev/null /usr/local/lib/docker/cli-plugins/docker-buildx; \
    curl -fsSL \
        "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    echo "${expected}  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c -

# 5: Ensure required groups exist.
# Groups are keyed by GID (the docker group must match the HOST's docker GID,
# passed via --build-arg, so sandbox users can reach a mounted Docker socket).
# The docker.io package may already have created a 'docker' group at a
# different GID: remove and recreate it at the requested one.
RUN set -eux; \
    if ! getent group "${GROUP_ID}" > /dev/null; then \
        if getent group coder > /dev/null; then groupdel coder; fi; \
        groupadd -g "${GROUP_ID}" coder; \
    fi; \
    if ! getent group "${DOCKER_GROUP}" > /dev/null; then \
        if getent group docker > /dev/null; then groupdel docker; fi; \
        groupadd -g "${DOCKER_GROUP}" docker; \
    fi; \
    usermod -u "${USER_ID}" node; \
    usermod -g "${GROUP_ID}" node; \
    usermod -a -G "${GROUP_ID},${DOCKER_GROUP}" node

# 5b: Allow the sandbox user to map subordinate UIDs/GIDs (required for
# rootless Docker; newuidmap/newgidmap come from the uidmap package).
# Known Debian packaging issue (shadow#958, rootlesskit#404, buildkit#2680):
# the packaged helpers fail inside containers. Fix: strip the setuid bit and
# grant file capabilities instead — with BOTH bits set, the (here broken)
# suid path takes precedence and multi-entry UID maps fail with EPERM.
RUN echo "node:100000:65536" >> /etc/subuid && \
    echo "node:100000:65536" >> /etc/subgid && \
    chmod 0755 /usr/bin/newuidmap /usr/bin/newgidmap && \
    setcap cap_setuid=ep /usr/bin/newuidmap && \
    setcap cap_setgid=ep /usr/bin/newgidmap

# 6: Install global npm packages from package.json
COPY package.json /tmp/package.json
RUN npm install -g --prefer-dedupe \
    --prefix /usr/local \
    $(node -e "const deps = require('/tmp/package.json').dependencies; console.log(Object.entries(deps).map(([k,v]) => v === 'latest' ? k : k + '@' + v).join(' '))") \
    && rm -rf /root/.npm /tmp/*

# engram MCP (version- and checksum-pinned; canonical upstream release artifact)
RUN set -eux; \
    if [ -z "${ENGRAM_SHA256}" ]; then \
        echo "ERROR: build-arg ENGRAM_SHA256 is empty - the Makefile must pass it via --build-arg (stale checkout? re-sync Makefile + Dockerfile together)" >&2; \
        exit 1; \
    fi; \
    engram_sha="$(printf '%s' "${ENGRAM_SHA256}" | tr -d '\r\n \t')"; \
    curl -fsSL -o /tmp/engram.tar.gz \
        "https://github.com/Gentleman-Programming/engram/releases/download/v${ENGRAM_VERSION}/engram_${ENGRAM_VERSION}_linux_amd64.tar.gz"; \
    echo "${engram_sha}  /tmp/engram.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/engram.tar.gz -C /tmp; \
    mv /tmp/engram /usr/local/bin/; \
    rm /tmp/engram.tar.gz

# 7: Create python venv + install Python deps from requirements.txt
COPY requirements.txt /tmp/requirements.txt
RUN python3 -m venv --system-site-packages /opt/venv && \
    PATH="/opt/venv/bin:$PATH" pip install --no-cache-dir -r /tmp/requirements.txt && \
    rm -f /tmp/requirements.txt

# 8: Install google-chrome (big layer)
# By default this uses ~/.cache/ms-playwright
RUN /opt/venv/bin/playwright install --with-deps \
    chrome-for-testing \
    chromium-headless-shell \
    && rm -rf /var/lib/apt/lists/* /root/.npm /tmp/*

# 8b: Install optional local Python modules from extra/ (if any): every
# subdirectory containing packaging metadata (pyproject.toml, setup.py or
# setup.cfg) is pip installed into the venv. The COPY is a silent no-op
# when the build context contains no extra/ directory.
COPY extra* /tmp/extra/
RUN set -eux; \
    count=0; \
    for d in /tmp/extra/*/; do \
        [ -d "$d" ] || continue; \
        if [ -f "${d}pyproject.toml" ] || [ -f "${d}setup.py" ] || [ -f "${d}setup.cfg" ]; then \
            pip install --no-cache-dir "$d"; \
            count=$((count + 1)); \
        else \
            echo "Skipping $d (no packaging metadata found)"; \
        fi; \
    done; \
    rm -rf /tmp/extra; \
    echo "Installed ${count} optional extra module(s)"

# 9: Set up some default locations for OpenCode
RUN mkdir -p /home/node/.local/share/opencode \
              /home/node/.local/state/opencode \
              /home/node/.cache/opencode \
              /home/node/.config/opencode && \
     chown -R node:node /home/node

# 10: Add some symlinks for browser discovery
RUN mkdir -p /opt/google/chrome/ && \
    fdfind '^chrome$' --type file /home/node/.agent-browser/browsers \
    -x ln -s {} /opt/google/chrome/chrome && \
    ln -s /opt/google/chrome/chrome /usr/local/bin/chrome

# TLS policy is enforced at runtime by the entrypoint:
# STRICT_TLS=1 (default) keeps Node.js certificate verification ENABLED;
# custom CAs installed at build time (step 2) are offered to Node via
# NODE_EXTRA_CA_CERTS. Set STRICT_TLS=0 only as an explicit INSECURE
# escape hatch.
ENV STRICT_TLS=1
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=0755 dockerd-sandboxed.sh /usr/local/bin/dockerd-sandboxed

USER node

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["opencode"]
