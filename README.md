# OpenCode Sandbox

A Docker-based sandboxed environment for running [OpenCode](https://opencode.ai)
with additional development tools and MCP servers pre-installed.

## Features

- **OpenCode** — AI-powered coding agent
- **agent-browser** — Browser automation via Playwright
- **Engram** — Persistent memory MCP server
- **codebase-memory-mcp** — Codebase knowledge graph
- **openspec-mcp** — Specification-driven development
- **Prettier, Biome, Ruff, Stylelint** — Linters and formatters
- **ShellCheck, yamllint** — Shell and YAML linting

## Prerequisites

- Docker

## Quick Start

```bash
# Build the sandbox image
make image

# Run OpenCode in the sandbox
make run
```

## Configuration

Configuration is managed via a `.env` file. Copy the example and adjust:

```bash
cp .env.example .env
```

### Environment Variables

| Variable                   | Default          | Description                                          |
| -------------------------- | ---------------- | ---------------------------------------------------- |
| `ENGRAM_VERSION`           | `1.20.0`         | Version of the Engram binary to download             |
| `LEMONADE_HOST`            | _(empty)_        | Hostname for `--add-host` mapping (set in `.env`)    |
| `HOST_LEMONADE`            | _(empty)_        | IP address to map `LEMONADE_HOST` to (for local dev) |
| `TARGET`                   | `example.com`    | Test target hostname for screenshot tests            |
| `OPENCODE_SERVER_USERNAME` | _(current user)_ | Username for `make server`                           |
| `OPENCODE_SERVER_PASSWORD` | _(current user)_ | Password for `make server`                           |

## Usage

### Build

```bash
make image     # Build without preflight checks
make run-tests # Run tests
```

### Run

```bash
make run      # Run OpenCode sandbox
make latest   # Run with "latest" tag
make bash     # Start a bash shell in the sandbox
make elevated # Run with Docker socket access
make server   # Run OpenCode server (requires OPENCODE_SERVER_PASSWORD)
```

### Test

```bash
make run-tests                # Run all tests inside Docker
make run-tests TYPE=linters   # Run only linter checks
make run-tests TYPE=updates   # Check for package updates
./test.sh [IMAGE_NAME] [TYPE] # Run tests locally
```

### Package

```bash
make package                  # Create a zip archive of build files
make package IMAGE_TAG=v1.0.0 # Tag the archive
```

## Project Structure

```
.
├── Dockerfile          # Docker image definition
├── .dockerignore       # Docker build exclusions
├── env.example        # Configuration template
├── Makefile            # Build and run targets
├── package.json        # npm dependencies
├── requirements.txt    # Python dependencies
└── test.sh             # Test script
```

## License

This project is licensed under the GNU General Public License v3.0 or later. See
[LICENSE](LICENSE) for details.

## Copyright

Copyright (C) 2026 Peter Mosmans
