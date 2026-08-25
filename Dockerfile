# Sandboxed OpenCode server with some additional tools and MCP servers

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# 1: Use a nice slim Debian-based image
FROM node:24-trixie-slim

ARG HOST_NAME=
ARG USER_ID=1001
ARG GROUP_ID=1001
ARG DOCKER_GROUP=111
# Browser versions
ARG ENGRAM_VERSION

# Set some sane OpenCode and Openspec defaults
ENV OPENSPEC_TELEMETRY=0
ENV OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS=36000000
ENV OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=262144
ENV OPENCODE_CONFIG_DIR=/home/node/.config/opencode
ENV OPENCODE_DISABLE_AUTOUPDATE=true
# Enable websearch - see https://opencode.ai/docs/tools/#websearch
ENV OPENCODE_ENABLE_EXA=1

ENV CURL_CA_BUNDLE=""
ENV DEBIAN_FRONTEND="noninteractive"

# Ensure that Chrome can run headless
ENV XDG_CONFIG_HOME=/home/node/.config
ENV XDG_CACHE_HOME=/home/node/.cache

# Ensure that both Playwright and agent-browser share the same browsers
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.agent-browser/browsers
ENV AGENT_BROWSER_EXECUTABLE_PATH=/opt/google/chrome/chrome

# Add Python package location to the path
ENV PATH="/opt/venv/bin:$PATH"

# 2: Copy SSL certs
COPY *.pem /etc/ssl/certs/
# 3: Optional - add certificate to CA bundle
RUN if [ -n "${HOST_NAME}" ]; then \
        echo "export CURL_CA_BUNDLE=/etc/ssl/certs/${HOST_NAME}.pem" > /etc/profile.d/curl-ca-bundle.sh; \
    fi

# 4: Install system packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bind9-dnsutils \
    ca-certificates \
    curl \
    fd-find \
    file \
    git \
    iputils-ping \
    jq \
    libxml2-utils \
    lsof \
    make \
    netcat-openbsd \
    openssh-client \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    shellcheck \
    sshpass \
    sudo \
    tree \
    unzip \
    whois \
    xxd \
    yamllint \
    zip \
    zsh && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# 5: Create group if it doesn't exist yet
RUN (getent group ${GROUP_ID} >/dev/null 2>&1 || groupadd -g ${GROUP_ID} coder 2>/dev/null) && \
    (getent group ${DOCKER_GROUP} >/dev/null 2>&1 || groupadd -g ${DOCKER_GROUP} docker) && \
    usermod -u ${USER_ID} node && \
    usermod -a -G ${GROUP_ID},${DOCKER_GROUP} node

# 6: Install global npm packages from package.json
COPY package.json /tmp/package.json
RUN npm install -g --prefer-dedupe \
    --prefix /usr/local \
    $(node -e "const deps = require('/tmp/package.json').dependencies; console.log(Object.entries(deps).map(([k,v]) => v === 'latest' ? k : k + '@' + v).join(' '))") \
    && rm -rf /root/.npm /tmp/*

# engram MCP
RUN curl -LO https://github.com/Gentleman-Programming/engram/releases/download/v${ENGRAM_VERSION}/engram_${ENGRAM_VERSION}_linux_amd64.tar.gz && \
tar -xzf engram_${ENGRAM_VERSION}_linux_amd64.tar.gz && \
mv engram /usr/local/bin/ && \
rm /engram_${ENGRAM_VERSION}_linux_amd64.tar.gz

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

# Disable TLS verification by default (for internal CA setups)
ENV NODE_TLS_REJECT_UNAUTHORIZED=0

USER node

CMD ["opencode"]
