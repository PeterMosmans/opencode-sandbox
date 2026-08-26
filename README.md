# OpenCode Sandbox

An all-in-one, Docker-based sandboxed environment for running
[OpenCode](https://opencode.ai) with additional development tools and MCP
servers pre-installed.

## Features

- **OpenCode** — AI-powered coding agent
- **agent-browser** — Browser automation via Playwright
- **Engram** — Persistent memory MCP server
- **codebase-memory-mcp** — Codebase knowledge graph
- **Prettier, Biome, Ruff, Stylelint** — Linters and formatters
- **ShellCheck, yamllint** — Shell and YAML linting

## Architecture

The OpenCode configuration directory itself, including skills, tools, and
agents, is mounted read-only.

```
# Enforce the configuration location
OPENCODE_CONFIG_DIR=/home/node/.config/opencode

# Map the original OpenCode config directory as read-only
~/.config/opencode:/home/node/.config/opencode:ro

# If it exists, the authentication file will also be mapped read-only
~/.local/share/opencode/auth.json:/home/node/.local/share/opencode/auth.json:ro
```

The project directory where opencode-sandbox is started, is mounted as
read-write project root.

Project-specific files like prompts and sessions are stored within the project
directory itself, under the `.memory` directory. This allows you to store and
resume sessions while still having a sandboxed environment.

```
$(PROJECT_ROOT)/.memory/codebase-memory-mcp/:/home/node/codebase-memory-mcp/:rw
$(PROJECT_ROOT)/.memory/engram/:/home/node/.engram/:rw
$(PROJECT_ROOT)/.memory/opencode/prompt-history.jsonl:/home/node/.local/state/opencode/prompt-history.jsonl:rw
$(PROJECT_ROOT)/.memory/opencode/opencode.db:/home/node/.local/share/opencode/opencode.db:rw
$(PROJECT_ROOT)/.memory/opencode/opencode.db-shm:/home/node/.local/share/opencode/opencode.db-shm:rw
$(PROJECT_ROOT)/.memory/opencode/opencode.db-wal:/home/node/.local/share/opencode/opencode.db-wal:rw
```

MCP servers like engram and Playwright live within the container. Configuration
files are mapped read-only, if they exist on the host.

```
~/.gitconfig:/home/node/.gitconfig:ro
~/.agent-browser/config.json:/home/node/.agent-browser/config.json:ro
```

## Prerequisites

- Docker
- make
- a working OpenCode configuration

## Quick Start

```bash
# Use the default .env file, adjust where needed
cp env.example .env

# Build the sandbox image
make image

# Run OpenCode in the sandbox
make run
```

## Docker Access Modes

| Mode               | Daemon                         | Escape reach          |
| ------------------ | ------------------------------ | --------------------- |
| `make run`         | none                           | sandbox only          |
| `make run-dind`    | private rootless daemon        | sandbox only          |
| `make elevated`    | **host** daemon (socket mount) | **game over — avoid** |

`make run-dind` starts a user-namespaced dockerd *inside* the container
(rootlesskit + slirp4netns + fuse-overlayfs). The agent can build and run
images fully autonomously, but there is no path to the host Docker instance.
Images and containers persist in `.memory/dind/`.

Notes:

- Requires unprivileged user namespaces on the host kernel (default on Linux,
  WSL2 and Docker Desktop). If startup fails with "operation not permitted":
  - Debian family / WSL: `sudo sysctl -w kernel.unprivileged_userns_clone=1`
  - Ubuntu 24.04+: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`
- DIND runs relax the outer seccomp filter (`seccomp=unconfined`) because the
  engine default blocks nested namespace/mount primitives, and disable
  `no-new-privileges` (default-on since Engine 25) so the setuid UID-map
  helpers work. The sandbox boundaries are unaffected: no host Docker socket,
  namespaced daemon, non-root user. Override with `DIND_SECURITY_FLAGS=`.
- Without `/dev/fuse`, the daemon falls back to the slower `vfs` storage
  driver. Override device flags with `DIND_DEVICE_FLAGS=` or pass extras via
  `DIND_EXTRA_FLAGS=`.
- `docker compose` is not installed; port publishing uses rootlesskit's
  builtin port driver.

There is also an **elevated** version, which gives the OpenCode container
access to the host Docker daemon. **Please note that this is not secure**, and
would allow (any process within) OpenCode to break out of the sandbox easily.
Only use it when the safer modes above are insufficient.

```
make run-elevated
```

This will map the following additional files:

```
/usr/bin/docker:/usr/bin/docker:ro
/usr/libexec/docker:/usr/libexec/docker:ro
/var/run/docker.sock:/var/run/docker.sock:ro
```

## Configuration

Configuration is managed via a `.env` file. Copy the example and adjust:

```bash
cp env.example .env
```

### Environment Variables

| Variable                   | Default          | Description                                          |
| -------------------------- | ---------------- | ---------------------------------------------------- |
| `ALLOW_WEAK_SERVER_CREDENTIALS` | `0`         | Set to `1` to allow weak server credentials          |
| `ENGRAM_VERSION`           | `1.20.0`         | Version of the Engram binary to download             |
| `GROUP`                    | default group    | Group name to be used in Docker container            |
| `HOST_LEMONADE`            | _(empty)_        | IP address to map `LEMONADE_HOST` to (for local dev) |
| `LEMONADE_HOST`            | _(empty)_        | Hostname for `--add-host` mapping (set in `.env`)    |
| `SERVER_BIND`              | `127.0.0.1`      | Bind address for the published server port           |
| `STRICT_TLS`               | `0`              | Set to `1` to enforce Node.js TLS verification       |
| `TARGET`                   | `example.com`    | Test target hostname for screenshot tests            |
| `OPENCODE_SERVER_USERNAME` | _(current user)_ | Username for `make server`                           |
| `OPENCODE_SERVER_PASSWORD` | _(current user)_ | Password for `make server` (weak values are refused) |

## Usage

### Build

```bash
make image     # Build without preflight checks
make run-tests # Run tests
```

### Run

```bash
make run       # Run OpenCode sandbox (no Docker access)
make run-dind  # Run with a private rootless Docker daemon (recommended)
make latest    # Run with "latest" tag
make bash      # Start a bash shell in the sandbox
make elevated  # Run with host Docker socket access (INSECURE, see above)
make server    # Run OpenCode server (requires OPENCODE_SERVER_PASSWORD)
```

### Test

```bash
make run-tests                # Run all tests inside Docker
make run-tests TYPE=linters   # Run only linter checks
make run-tests TYPE=updates   # Check for package updates
./test.sh [IMAGE_NAME] [TYPE] # Run tests locally
```

## License

This project is licensed under the GNU General Public License v3.0 or later. See
[LICENSE](LICENSE) for details.

## Copyright

Copyright (C) 2026 Peter Mosmans
