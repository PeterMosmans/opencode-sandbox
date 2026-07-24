# Generic Makefile for a sandboxed OpenCode environment
# Create a (new) OpenCode sandbox Docker image, and run OpenCode sandboxed

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# Runs OpenCode sandboxed
# In order to do this, the following files/directories are shared READ-ONLY:
# ~/.config/opencode - contains OpenCode configuration (set using OPENCODE_CONFIG_DIR)
# ~/.gitconfig
#
# The following files/directories are exclusive within the project directory
# .memory/agentmemory - agentmemory MCP
# .memory/codebase-memory-mcp - (set using CBM_CACHE_DIR)
# .memory/opencode - OpenCode session database and prompt history
# .memory/engram - Engram

# Enforce Bash as shell, as that makes it easier to script
SHELL := /bin/bash

# Detect platform for cross-platform compatibility
IS_DARWIN := $(shell uname -s 2>/dev/null | grep -q Darwin && echo 1 || echo 0)

# Docker elevated flags (Linux mounts docker binaries, macOS only mounts socket)
ifeq ($(IS_DARWIN),1)
DOCKER_ELEVATED_FLAGS :=
else
DOCKER_ELEVATED_FLAGS := --group-add docker -v /usr/bin/docker:/usr/bin/docker:ro -v /usr/libexec/docker:/usr/libexec/docker:ro -v /var/run/docker.sock:/var/run/docker.sock:ro
endif

# sed -i flag differs between macOS (requires empty suffix) and Linux
ifeq ($(IS_DARWIN),1)
SED_I := sed -i ''
else
SED_I := sed -i
endif

# Use current directory as root for the sandbox
PROJECT_NAME := $(notdir $(CURDIR))
IMAGE_NAME := opencode-sandbox-$(shell id -u)
TEST_IMAGE_NAME := $(IMAGE_NAME)-test
PROJECT_ROOT ?= $(CURDIR)

# Directory where the Makefile lives (for git operations)
MAKE_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
# Port on which to test https:// connection
HOST_PORT ?= 8000

# Source .env for version overrides (if it exists)
ifneq ($(wildcard .env),)
include .env
endif

# OpenCode version is derived from the opencode-ai dependency in package.json.
# Override via .env (OPENCODE_VERSION=...) if needed.
OPENCODE_VERSION ?= $(shell node -e "console.log(require('./package.json').dependencies['opencode-ai'])")
OPENCODE_SERVER_USERNAME ?= $(shell id -u --name)
OPENCODE_SERVER_PASSWORD ?= $(shell id -u --name)
# Image tag defaults to "latest" for day-to-day builds. Override to tag
# with the release version or any custom tag:
#	make build					   → builds & tags as "latest"
#	make build IMAGE_TAG=$(OPENCODE_VERSION) → tags with the release version
#	make build IMAGE_TAG=abc1234   → tags with a commit/sha
IMAGE_TAG ?= latest
# Group for sandboxed runs
GROUP ?= pentester
SANDBOX_GID := $(shell getent group $(GROUP) | cut -d: -f3)
# ANSI color codes (escaped for Make compatibility)
BOLD   := \033[1m
BLUE   := \033[1;34m
GREEN  := \033[32m
RED	   := \033[0;31m
YELLOW := \033[0;33m
RESET  := \033[0m

# Colorized message helper
define color_msg
	@printf '%b%b%b\n' '$(BLUE)' '$1' '$(RESET)'
endef

define bold_msg
	@printf '%b%b%b\n' '$(BOLD)' '$1' '$(RESET)'
endef

define status_msg
	@printf '%b%s %s%b\n' '$(GREEN)' '$1:' '$(BOLD)' '$(RESET)'
endef

# Help first: This will be the default target
help: # Display useful commands
	@grep -E '^[a-zA-Z_-]+:.*\s+#\s' Makefile | \
	awk 'BEGIN {FS = ":.*?# "}; {printf "\033[1;33m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight preflight-run preflight-elevated build run latest elevated test clean image custom-image test-image test-run run-tests server package update-versions check-versions tag-version

preflight: # Check prerequisites before building
	@printf '%b%s%b\n' '$(BOLD)' 'Running preflight checks...' '$(RESET)'
	@command -v docker >/dev/null 2>&1 || { printf '%b%s%b\n' '$(RED)' 'ERROR: docker is not installed' '$(RESET)'; exit 1; }
	@docker info >/dev/null 2>&1 || { printf '%b%s%b\n' '$(RED)' 'ERROR: docker daemon is not running' '$(RESET)'; exit 1; }
	@test -f Dockerfile || { printf '%b%s%b\n' '$(RED)' "ERROR: Dockerfile not found in $(CURDIR)" '$(RESET)'; exit 1; }
	@test -d ~/.config/opencode || { printf '%b%s%b\n' '$(RED)' 'ERROR: ~/.config/opencode directory not found (required for run)' '$(RESET)'; exit 1; }
	@test -f ~/.local/share/opencode/auth.json || { printf '%b%s%b\n' '$(RED)' 'ERROR: ~/.local/share/opencode/auth.json not found (required for run/elevated)' '$(RESET)'; exit 1; }
	@printf '%b%s%b\n' '$(GREEN)' 'All preflight checks passed.' '$(RESET)'

preflight-run: # Check prerequisites for run and elevated commands
	@printf '%b%s%b\n' '$(BOLD)' 'Running preflight checks for run...' '$(RESET)'
	@test "$(CURDIR)" != "$(HOME)" || { printf '%b%s%b\n' '$(RED)' 'ERROR: Cannot run from home directory ($(CURDIR)) — this would map your entire home into the sandbox' '$(RESET)'; exit 1; }
	@test -d ~/.config/opencode || { printf '%b%s%b\n' '$(RED)' 'ERROR: ~/.config/opencode directory not found (required for run/)' '$(RESET)'; exit 1; }
	@test -f ~/.local/share/opencode/auth.json || { printf '%b%s%b\n' '$(RED)' 'ERROR: ~/.local/share/opencode/auth.json not found (required for run)' '$(RESET)'; exit 1; }
	@test -f ~/.gitconfig || { printf '%b%s%b\n' '$(RED)' 'ERROR: ~/.gitconfig not found (required for run)' '$(RESET)'; exit 1; }
	@mkdir -p .memory/{agentmemory,codebase-memory-mcp,engram,opencode} 2>/dev/null; \
	touch .memory/opencode/{opencode.db{,-shm,-wal},prompt-history.jsonl}
	@printf '%b%s%b\n' '$(GREEN)' 'All run/elevated preflight checks passed.' '$(RESET)'

preflight-elevated: preflight-run # Additional checks for elevated command
	@printf '%b%s%b\n' '$(BOLD)' 'Running preflight checks for elevated...' '$(RESET)'
ifeq ($(IS_DARWIN),1)
	@test -f /usr/local/bin/docker || { printf '%b%s%b\n' '$(RED)' 'ERROR: /usr/local/bin/docker not found (Docker Desktop required for elevated)' '$(RESET)'; exit 1; }
else
	@test -f /usr/bin/docker || { printf '%b%s%b\n' '$(RED)' 'ERROR: /usr/bin/docker not found (required for elevated)' '$(RESET)'; exit 1; }
	@test -d /usr/libexec/docker || { printf '%b%s%b\n' '$(RED)' 'ERROR: /usr/libexec/docker directory not found (required for elevated)' '$(RESET)'; exit 1; }
endif
	@printf '%b%s%b\n' '$(GREEN)' 'All elevated preflight checks passed.' '$(RESET)'

build: preflight image # Build a fresh OpenCode sandbox (with preflight check)

# Shared docker build arguments (non-npm packages and runtime config only)
DOCKER_BUILD_ARGS := \
	--build-arg ENGRAM_VERSION=$(ENGRAM_VERSION) \
	--build-arg HOST_NAME=$(HOST_NAME) \
	--build-arg USER_ID=$$(id -u) \
	--build-arg GROUP_ID=$(SANDBOX_GID)

image: # Build a fresh OpenCode sandbox
	@printf '%b%s%b\n' '$(BLUE)' 'Building image: $(IMAGE_NAME)...' '$(RESET)'
	docker build . -t $(IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS)

tag-version: # Tag the latest image with the opencode-ai version from package.json
	@docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(OPENCODE_VERSION)
	@printf '%b%s%b\n' '$(GREEN)' "Tagged $(IMAGE_NAME):latest → $(IMAGE_NAME):$(OPENCODE_VERSION)" '$(RESET)'

CUSTOM_IMAGE_NAME ?= sandbox-opencode-custom-$(shell id -u)

SERVER_PORT ?= 5000

custom-image: # Build image from alternative Dockerfile with different name
	@test -f Dockerfile.custom || { printf '%b%s%b\n' '$(RED)' 'ERROR: Dockerfile.custom not found' '$(RESET)'; exit 1; }
	@printf '%b%s%b\n' '$(BLUE)' "Building image: $(CUSTOM_IMAGE_NAME)..." '$(RESET)'
	@docker build -f Dockerfile.custom . -t $(CUSTOM_IMAGE_NAME) -t $(CUSTOM_IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS)

test-image: preflight # Build a test OpenCode sandbox image
	@printf '%b%s%b\n' '$(BLUE)' "Building test image: $(TEST_IMAGE_NAME)..." '$(RESET)'
	@docker build . -t $(TEST_IMAGE_NAME) -t $(TEST_IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS) --progress=plain

HOST_LEMONADE ?=

# Shared docker run options for standard sandbox containers
# /home/node/.local/state/opencode/prompt-history.jsonl:rw
# -v $(PROJECT_ROOT)/.opencode/opencode.db:/home/node/.local/share/opencode/opencode.db
# Conditionally mount files only if they exist
# /home/node/codebase-memory-mcp/ For codebase meory:
# -v $(PROJECT_ROOT)/.cache:/home/node/.cache/opencode/:rw 
SANDBOX_MOUNTS := $(shell \
  m="-u $$(id -u):$(SANDBOX_GID) \
-e OPENCODE_CONFIG_DIR=/home/node/.config/opencode \
-v $(PROJECT_ROOT)/.memory/codebase-memory-mcp/:/home/node/codebase-memory-mcp/:rw \
-v $(PROJECT_ROOT)/.memory/engram/:/home/node/.engram/:rw \
-v $(PROJECT_ROOT)/.memory/opencode/prompt-history.jsonl:/home/node/.local/state/opencode/prompt-history.jsonl:rw \
-v $(PROJECT_ROOT)/.memory/opencode/opencode.db:/home/node/.local/share/opencode/opencode.db:rw \
-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-shm:/home/node/.local/share/opencode/opencode.db-shm:rw \
-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-wal:/home/node/.local/share/opencode/opencode.db-wal:rw \
-v $(PROJECT_ROOT):/$(PROJECT_NAME):rw \
-v ~/.config/opencode:/home/node/.config/opencode:ro \
-v ~/.local/share/opencode/auth.json:/home/node/.local/share/opencode/auth.json:ro \
 -w /$(PROJECT_NAME) \
"; \
  [ -n "$(HOST_LEMONADE)" ] && m="$$m --add-host $(LEMONADE_HOST):$(HOST_LEMONADE)"; \
  [ -f ~/.gitconfig ] && m="$$m -v ~/.gitconfig:/home/node/.gitconfig:ro"; \
  [ -f ~/.agent-browser/config.json ] && m="$$m -v ~/.agent-browser/config.json:/home/node/.agent-browser/config.json:ro"; \
  echo "$$m")

run: preflight-run # Run OpenCode sandboxed in the current directory
	@printf '%b%s%b\n' '$(BLUE)' 'Running sandbox image:' '$(RESET)'
	@printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(IMAGE_NAME):" "$(IMAGE_TAG)"
	@if [ -n "$(HOST_LEMONADE)" ]; then \
		printf '%b%s%b\n' '$(GREEN)' "  -> $(LEMONADE_HOST) mapped to $(HOST_LEMONADE)" '$(RESET)'; \
	fi
	@docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):$(IMAGE_TAG)

latest: preflight-run # Run OpenCode sandboxed in the current directory
	@printf '%b%s%b\n' '$(BLUE)' 'Running sandbox image:' '$(RESET)'
	@printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(IMAGE_NAME):" "$(IMAGE_TAG)"
	@if [ -n "$(HOST_LEMONADE)" ]; then \
		printf '%b%s%b\n' '$(GREEN)' "  -> $(LEMONADE_HOST) mapped to $(HOST_LEMONADE)" '$(RESET)'; \
	fi
	@docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest

bash:
	docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest /bin/bash

mcptest:
	docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest opencode mcp list

mcpdoctor:
	docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest agentmemory doctor

validate:
	@docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):$(IMAGE_TAG) opencode stats

custom:	 # Run OpenCode sandboxed in the current directory
	@docker run --rm -it $(SANDBOX_MOUNTS) $(CUSTOM_IMAGE_NAME)

server: preflight-run # Run OpenCode server in the current directory
	@test -n "$(OPENCODE_SERVER_PASSWORD)" || { printf '%b%s%b\n' '$(RED)' 'ERROR: OPENCODE_SERVER_PASSWORD must be set' '$(RESET)'; exit 1; }
	@printf '%b%s%b\n' '$(BLUE)' 'Running server in $(PROJECT_NAME) with username $(OPENCODE_SERVER_USERNAME) and password $(OPENCODE_SERVER_PASSWORD) on port $(SERVER_PORT):' '$(RESET)'
	@printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(IMAGE_NAME):" "$(IMAGE_TAG)"
	@docker run --init --rm -it \
		-e OPENCODE_SERVER_USERNAME=$(OPENCODE_SERVER_USERNAME) \
		-e OPENCODE_SERVER_PASSWORD=$(OPENCODE_SERVER_PASSWORD) \
		-p $(SERVER_PORT):$(SERVER_PORT) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		/bin/bash -c "cd /$(PROJECT_NAME) && opencode serve --port $(SERVER_PORT) --hostname 0.0.0.0"

test-run: preflight-run # Run OpenCode test sandboxed in the current directory
	@printf '%b%s%b\n' '$(BLUE)' 'Running test image:' '$(RESET)'
	@printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(TEST_IMAGE_NAME):" "$(IMAGE_TAG)"
	@docker run --rm -it $(SANDBOX_MOUNTS) $(TEST_IMAGE_NAME)

elevated: preflight-elevated # Run OpenCode sandboxed with Docker access
	@if [ -n "$(HOST_LEMONADE)" ]; then \
		printf '%b%s%b\n' '$(GREEN)' "  -> $(LEMONADE_HOST) mapped to $(HOST_LEMONADE)" '$(RESET)'; \
	fi
	@docker run --rm -it \
		$(DOCKER_ELEVATED_FLAGS) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME)

# Tests are in test.sh
# Usage: ./test.sh [IMAGE_NAME] [TEST_TYPE]
#	IMAGE_NAME : Docker image to test (default: $(IMAGE_NAME))
#	TYPE  : linters, agent, full, updates (default: full)
#
# Run tests inside Docker: make run-tests TYPE=full
# Run tests locally:        ./test.sh [IMAGE_NAME] [TYPE]

run-tests: preflight-run # Run tests inside Docker container (make run-tests IMAGE=my-image TYPE=full)
	@test -x test.sh || { printf '%b%s%b\n' '$(RED)' 'test.sh not found or not executable' '$(RESET)'; exit 1; }
	@printf '%b%s%b\n' '$(BLUE)' "Running tests inside Docker container..." '$(RESET)'
	@printf '%b%s%b\n' '$(BLUE)' "  Image: ${IMAGE:-$(IMAGE_NAME)}" '$(RESET)'
	@printf '%b%s%b\n' '$(BLUE)' "  Type:  ${TYPE:-full}" '$(RESET)'
	@mkdir -p tests/ 2>/dev/null
	@docker run --rm -it \
		$(SANDBOX_MOUNTS) \
		$(DOCKER_ELEVATED_FLAGS) \
	    -v ./tests:/tests:rw \
		-v $(CURDIR)/test.sh:/home/node/test.sh:ro \
		-u $$(id -u):$(SANDBOX_GID) \
		$(IMAGE_NAME) \
		/bin/bash /home/node/test.sh "${IMAGE:-$(IMAGE_NAME)}" "${TYPE:-full}" bare

# Shared docker image removal pattern
IMAGE_PATTERNS := $(IMAGE_NAME) $(IMAGE_NAME):* $(TEST_IMAGE_NAME) $(TEST_IMAGE_NAME):* $(CUSTOM_IMAGE_NAME) $(CUSTOM_IMAGE_NAME):*

clean: remove # Remove sandbox Docker images
	@docker image prune -f

remove: # Remove all sandbox image variants (tags and untagged)
	@for img in $(IMAGE_PATTERNS); do \
		docker rmi --force "$$img" 2>/dev/null || true; \
	done

PACKED_FILES := .env Dockerfile .dockerignore Makefile test.sh README.md package.json requirements.txt

package: # Create a zip archive with all files needed to build and test the image, named with version tag
	@zip -q "sandbox-$(IMAGE_TAG).zip" $(PACKED_FILES)
	@printf '%b%s%b: %s\n' '$(GREEN)' 'Created' '$(RESET)' '"sandbox-$(IMAGE_TAG).zip"'

# Update npm + pip package versions by fetching latest from registries
update-versions: # Update package.json + requirements.txt with latest versions
	@echo "Fetching latest versions from npm and updating package.json..."
	@node -e "\
	const pkg = require('./package.json'); \
	const deps = pkg.dependencies; \
	const packages = Object.keys(deps); \
	const npm = require('child_process').execSync; \
	let changed = 0; \
	packages.forEach(pkgName => { \
		try { \
			const latest = npm('npm view ' + pkgName + ' version', {encoding: 'utf8'}).trim(); \
			const current = deps[pkgName]; \
			if (current === 'latest') { \
				console.log(pkgName + ': latest (skipping)'); \
			} else if (current !== latest) { \
				deps[pkgName] = latest; \
				console.log('Updated: ' + pkgName + ' -> ' + latest); \
				changed++; \
			} else { \
				console.log(pkgName + ': up to date (' + current + ')'); \
			} \
		} catch(e) { \
			console.log(pkgName + ': could not fetch latest version (skipping)'); \
		} \
	}); \
	if (changed > 0) { \
		pkg.dependencies = deps; \
		const fs = require('fs'); \
		fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n'); \
		console.log('Done. package.json updated.'); \
	} else { \
		console.log('No npm packages need updating.'); \
	} \
	"
	@echo ""
	@echo "Fetching latest versions from PyPI and updating requirements.txt..."
	@changed=0; \
	while IFS= read -r line || [ -n "$$line" ]; do \
		[ -z "$$line" ] && continue; \
		[ "$${line:0:1}" = "#" ] && continue; \
		pkg_name=$$(echo "$$line" | cut -d= -f1); \
		pkg_version=$$(echo "$$line" | cut -d= -f3); \
		latest=$$(pip index versions "$$pkg_name" 2>/dev/null | head -1 | sed 's/.*(\(.*\))/\1/'); \
		if [ -n "$$latest" ]; then \
			if [ "$$pkg_version" != "$$latest" ]; then \
				echo "Updated: $$pkg_name == $$pkg_version -> $$latest"; \
				sed -i "s/^$$pkg_name==.*/$$pkg_name==$$latest/" requirements.txt; \
				changed=$$((changed + 1)); \
			else \
				echo "$$pkg_name: up to date ($$pkg_version)"; \
			fi; \
		else \
			echo "Skipped: $$pkg_name (could not fetch version)"; \
		fi; \
	done < requirements.txt; \
	if [ "$$changed" -gt 0 ]; then \
		echo "Done. requirements.txt updated."; \
	else \
		echo "No pip packages need updating."; \
	fi

# Check if npm + pip package versions are up to date
check-versions: # Compare package.json + requirements.txt versions against registries
	@UP_TO_DATE=0 && \
	OUTDATED=0 && \
	echo "Checking package.json versions against npm..." && \
	_tmp=$$(mktemp) && \
	node -e "\
	const pkg = require('./package.json'); \
	const deps = pkg.dependencies; \
	const packages = Object.keys(deps); \
	const npm = require('child_process').execSync; \
	let upToDate = 0; \
	let outdated = 0; \
	packages.forEach(pkgName => { \
		try { \
			const latest = npm('npm view ' + pkgName + ' version', {encoding: 'utf8'}).trim(); \
			const current = deps[pkgName]; \
			if (current === 'latest') { \
				console.log(pkgName + ': latest (skipping)'); \
			} else if (current !== latest) { \
				console.log(pkgName + ': ' + current + ' -> ' + latest); \
				outdated++; \
			} else { \
				console.log(pkgName + ': up to date (' + current + ')'); \
				upToDate++; \
			} \
		} catch(e) { \
			console.log(pkgName + ': could not fetch latest version (skipping)'); \
		} \
	}); \
	console.log(upToDate + ' ' + outdated); \
	" > "$$_tmp" 2>&1 && \
	tail -n +1 "$$_tmp" | head -n -1 && \
	NPM_SUMMARY=$$(tail -1 "$$_tmp") && \
	rm -f "$$_tmp" && \
	UP_TO_DATE=$$(echo "$$NPM_SUMMARY" | awk '{print $$1}') && \
	OUTDATED=$$(echo "$$NPM_SUMMARY" | awk '{print $$2}') && \
	echo "" && \
	echo "Checking requirements.txt versions against PyPI..." && \
	while IFS= read -r line || [ -n "$$line" ]; do \
		[ -z "$$line" ] && continue; \
		[ "$${line:0:1}" = "#" ] && continue; \
		pkg_name=$$(echo "$$line" | cut -d= -f1); \
		pkg_version=$$(echo "$$line" | cut -d= -f3); \
		latest=$$(pip index versions "$$pkg_name" 2>/dev/null | head -1 | sed 's/.*(\(.*\))/\1/'); \
		if [ -n "$$latest" ]; then \
			if [ "$$pkg_version" != "$$latest" ]; then \
				echo "$$pkg_name: $$pkg_version -> $$latest"; \
				OUTDATED=$$((OUTDATED + 1)); \
			else \
				echo "$$pkg_name: up to date ($$pkg_version)"; \
				UP_TO_DATE=$$((UP_TO_DATE + 1)); \
			fi; \
		else \
			echo "$$pkg_name: could not fetch latest version (skipping)"; \
		fi; \
	done < requirements.txt && \
	echo "" && \
	echo "Summary: $$UP_TO_DATE up to date, $$OUTDATED out of date." && \
	exit $$OUTDATED
