# Generic Makefile for a sandboxed OpenCode environment
# Create a (new) OpenCode sandbox Docker image, and run OpenCode sandboxed

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck disable=SC1073,SC1065,SC1064,SC1072

# Runs OpenCode sandboxed
# In order to do this, the following files/directories are shared READ-ONLY:
# ~/.config/opencode - contains OpenCode configuration (set using OPENCODE_CONFIG_DIR)
# ~/.gitconfig
#
# The following files/directories are exclusive within the project directory
# .memory/codebase-memory-mcp - (set using CBM_CACHE_DIR)
# .memory/opencode - OpenCode session database and prompt history
# .memory/engram - Engram

# === Configuration ===

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

# Source .env for version overrides (if it exists)
ifneq ($(wildcard .env),)
include .env
endif

# Project configuration
PROJECT_NAME := $(notdir $(CURDIR))
IMAGE_NAME := opencode-sandbox-$(shell id -u)
TEST_IMAGE_NAME := $(IMAGE_NAME)-test
PROJECT_ROOT ?= $(CURDIR)
CUSTOM_IMAGE_NAME ?= sandbox-opencode-custom-$(shell id -u)

# Directory where the Makefile lives (for git operations)
MAKE_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))

# Port on which to test https:// connection
HOST_PORT ?= 8000

# OpenCode version is derived from the opencode-ai dependency in package.json.
# Override via .env (OPENCODE_VERSION=...) if needed.
OPENCODE_VERSION ?= $(shell node -e "console.log(require('./package.json').dependencies['opencode-ai'])")
OPENCODE_SERVER_USERNAME ?= $(shell id -u --name)
OPENCODE_SERVER_PASSWORD ?= $(shell id -u --name)
ENGRAM_VERSION ?= 1.20.0
TARGET ?= example.com

# Image tag defaults to "latest" for day-to-day builds. Override to tag
# with the release version or any custom tag:
#	make build					   → builds & tags as "latest"
#	make build IMAGE_TAG=$(OPENCODE_VERSION) → tags with the release version
#	make build IMAGE_TAG=abc1234   → tags with a commit/sha
IMAGE_TAG ?= latest

# Group for sandboxed runs
GROUP ?= $(shell id -gn)

# HOST_LEMONADE maps a hostname to an IP for local development
HOST_LEMONADE ?=

# Server configuration
SERVER_PORT ?= 5000

# Test configuration
TYPE ?= full

# === Helpers ===

# ANSI color codes (escaped for Make compatibility)
BOLD   := \033[1m
BLUE   := \033[1;34m
GREEN  := \033[32m
RED	   := \033[0;31m
YELLOW := \033[0;33m
RESET  := \033[0m

# Colorized message helpers
define color_msg
printf '%b%b%b\n' '$(BLUE)' '$1' '$(RESET)'
endef

define bold_msg
printf '%b%b%b\n' '$(BOLD)' '$1' '$(RESET)'
endef

define status_msg
printf '%b%s%b\n' '$(GREEN)' '$1:' '$(RESET)'
endef

define error_msg
printf '%b%s%b\n' '$(RED)' '$1' '$(RESET)'
endef

# Display HOST_LEMONADE mapping
define show_lemonade
if [ -n "$(HOST_LEMONADE)" ]; then \
printf '%b%s%b\n' '$(GREEN)' '  -> $(LEMONADE_HOST) mapped to $(HOST_LEMONADE)' '$(RESET)'; \
fi
endef

# Display image tag information (first argument = tag)
define show_image_tag
printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(IMAGE_NAME):" "$(1)"
endef

# === Derived Variables ===

# Group ID for sandboxed runs
SANDBOX_GID := $(shell getent group $(GROUP) | cut -d: -f3)

# Base mounts always included in sandbox runs
SANDBOX_BASE_MOUNTS := -u $$(id -u):$(SANDBOX_GID) \
	-e OPENCODE_CONFIG_DIR=/home/node/.config/opencode \
	-v $(PROJECT_ROOT)/.memory/codebase-memory-mcp/:/home/node/codebase-memory-mcp/:rw \
	-v $(PROJECT_ROOT)/.memory/engram/:/home/node/.engram/:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/prompt-history.jsonl:/home/node/.local/state/opencode/prompt-history.jsonl:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db:/home/node/.local/share/opencode/opencode.db:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-shm:/home/node/.local/share/opencode/opencode.db-shm:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-wal:/home/node/.local/share/opencode/opencode.db-wal:rw \
	-v $(PROJECT_ROOT):/$(PROJECT_NAME):rw \
	-v ~/.config/opencode:/home/node/.config/opencode:ro \
	-w /$(PROJECT_NAME)

# Base mounts for ephemeral runs (no .memory/ volume mappings)
SANDBOX_BASE_MOUNTS_EPHEMERAL := -u $$(id -u):$(SANDBOX_GID) \
	-e OPENCODE_CONFIG_DIR=/home/node/.config/opencode \
	-v $(PROJECT_ROOT):/$(PROJECT_NAME):rw \
	-v ~/.config/opencode:/home/node/.config/opencode:ro \
	-w /$(PROJECT_NAME)

# Optional conditional mounts
SANDBOX_OPTIONAL_MOUNTS := \
	$(if $(HOST_LEMONADE),--add-host $(LEMONADE_HOST):$(HOST_LEMONADE)) \
	$(if $(wildcard ~/.gitconfig),-v ~/.gitconfig:/home/node/.gitconfig:ro) \
	$(if $(wildcard ~/.agent-browser/config.json),-v ~/.agent-browser/config.json:/home/node/.agent-browser/config.json:ro) \
	$(if $(wildcard ~/.local/share/opencode/auth.json),-v ~/.local/share/opencode/auth.json:/home/node/.local/share/opencode/auth.json:ro)

# Final SANDBOX_MOUNTS composed of base + optional
SANDBOX_MOUNTS := $(SANDBOX_BASE_MOUNTS) $(SANDBOX_OPTIONAL_MOUNTS)

# Ephemeral mounts (no .memory/ mappings)
SANDBOX_MOUNTS_EPHEMERAL := $(SANDBOX_BASE_MOUNTS_EPHEMERAL) $(SANDBOX_OPTIONAL_MOUNTS)

# Shared docker build arguments (non-npm packages and runtime config only)
DOCKER_BUILD_ARGS := \
	--build-arg ENGRAM_VERSION=$(ENGRAM_VERSION) \
	--build-arg HOST_NAME=$(HOST_NAME) \
	--build-arg USER_ID=$$(id -u) \
	--build-arg GROUP_ID=$(SANDBOX_GID)

# Shared docker image removal pattern
IMAGE_PATTERNS := $(IMAGE_NAME) $(IMAGE_NAME):* $(TEST_IMAGE_NAME) $(TEST_IMAGE_NAME):* $(CUSTOM_IMAGE_NAME) $(CUSTOM_IMAGE_NAME):*

# Files included in package archive
PACKED_FILES := env.example Dockerfile .dockerignore Makefile test.sh README.md package.json requirements.txt

# === .PHONY ===
.PHONY: help preflight preflight-run preflight-elevated build run latest elevated bash test clean image custom-image test-image test-run run-tests server package update-versions check-versions tag-version validate test-makefile run-ephemeral

# === Building ===

# Help first: This will be the default target
help: # Display useful commands
	@grep -E '^[a-zA-Z_-]+:.*\s+#\s' Makefile | \
	awk 'BEGIN {FS = ":.*?# "}; {printf "\033[1;33m%-20s\033[0m %s\n", $$1, $$2}'

preflight: # Check prerequisites before building
	@$(call bold_msg,Running preflight checks...)
	@command -v docker >/dev/null 2>&1 || { $(call error_msg,ERROR: docker is not installed); exit 1; }
	@docker info >/dev/null 2>&1 || { $(call error_msg,ERROR: docker daemon is not running); exit 1; }
	@test -f Dockerfile || { $(call error_msg,ERROR: Dockerfile not found in $(CURDIR)); exit 1; }
	@test -d ~/.config/opencode || { $(call error_msg,ERROR: ~/.config/opencode directory not found (required for run)); exit 1; }
	@$(call status_msg,All preflight checks passed)

preflight-run: # Check prerequisites for run and elevated commands
	@$(call bold_msg,Running preflight checks for run...)
	@test "$(CURDIR)" != "$(HOME)" || { $(call error_msg,ERROR: Cannot run from home directory ($(CURDIR)) — this would map your entire home into the sandbox); exit 1; }
	@test -d ~/.config/opencode || { $(call error_msg,ERROR: ~/.config/opencode directory not found (required for run/)); exit 1; }
	@mkdir -p .memory/{codebase-memory-mcp,engram,opencode} 2>/dev/null; \
	touch .memory/opencode/{opencode.db{,-shm,-wal},prompt-history.jsonl}
	@$(call status_msg,All run/elevated preflight checks passed)

preflight-elevated: preflight-run # Additional checks for elevated command
	@$(call bold_msg,Running preflight checks for elevated...)
ifeq ($(IS_DARWIN),1)
	@test -f /usr/local/bin/docker || { $(call error_msg,ERROR: /usr/local/bin/docker not found (Docker Desktop required for elevated)); exit 1; }
else
	@test -f /usr/bin/docker || { $(call error_msg,ERROR: /usr/bin/docker not found (required for elevated)); exit 1; }
	@test -d /usr/libexec/docker || { $(call error_msg,ERROR: /usr/libexec/docker directory not found (required for elevated)); exit 1; }
endif
	@$(call status_msg,All elevated preflight checks passed)

build: preflight image # Build a fresh OpenCode sandbox (with preflight check)

image: # Build a fresh OpenCode sandbox
	@$(call color_msg,Building image: $(IMAGE_NAME)...)
	docker build . -t $(IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS)

tag-version: # Tag the latest image with the opencode-ai version from package.json
	@docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(OPENCODE_VERSION)
	@printf '%b%s%b %s\n' '$(GREEN)' 'Tagged $(IMAGE_NAME):latest → $(IMAGE_NAME):$(OPENCODE_VERSION)' '$(RESET)'

custom-image: # Build image from alternative Dockerfile with different name
	@test -f Dockerfile.custom || { $(call error_msg,ERROR: Dockerfile.custom not found); exit 1; }
	@$(call color_msg,Building image: $(CUSTOM_IMAGE_NAME)...)
	@docker build -f Dockerfile.custom . -t $(CUSTOM_IMAGE_NAME) -t $(CUSTOM_IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS)

test-image: preflight # Build a test OpenCode sandbox image
	@$(call color_msg,Building test image: $(TEST_IMAGE_NAME)...)
	@docker build . -t $(TEST_IMAGE_NAME) -t $(TEST_IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS) --progress=plain

# === Running ===

TAG ?= $(IMAGE_TAG)

run: preflight-run # Run OpenCode sandboxed in the current directory
	@$(call color_msg,Running sandbox image:)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	@docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):$(TAG)

run-ephemeral: # Run OpenCode sandboxed without .memory/ mappings (ephemeral)
	@$(call color_msg,Running ephemeral sandbox image:)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	docker run --rm -it $(SANDBOX_MOUNTS_EPHEMERAL) $(IMAGE_NAME):$(TAG)

latest: TAG = latest
latest: run # Run OpenCode sandboxed with latest tag

bash: # Run a bash shell
	docker run --rm -it $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest /bin/bash

server: preflight-run # Run OpenCode server in the current directory
	@test -n "$(OPENCODE_SERVER_PASSWORD)" || { $(call error_msg,ERROR: OPENCODE_SERVER_PASSWORD must be set); exit 1; }
	@$(call color_msg,Running server in $(PROJECT_NAME) with username $(OPENCODE_SERVER_USERNAME) and password $(OPENCODE_SERVER_PASSWORD) on port $(SERVER_PORT):)
	@$(call show_image_tag,$(IMAGE_TAG))
	@docker run --init --rm -it \
		-e OPENCODE_SERVER_USERNAME=$(OPENCODE_SERVER_USERNAME) \
		-e OPENCODE_SERVER_PASSWORD=$(OPENCODE_SERVER_PASSWORD) \
		-p $(SERVER_PORT):$(SERVER_PORT) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		/bin/bash -c "cd /$(PROJECT_NAME) && opencode serve --port $(SERVER_PORT) --hostname 0.0.0.0"

test-run: preflight-run # Run OpenCode test sandboxed in the current directory
	@$(call color_msg,Running test image:)
	@printf '  -> Image tag: %s\033[1m%s\033[0m\n' "$(TEST_IMAGE_NAME):" "$(IMAGE_TAG)"
	@docker run --rm -it $(SANDBOX_MOUNTS) $(TEST_IMAGE_NAME)

elevated: preflight-elevated # Run OpenCode sandboxed with Docker access
	@$(call show_lemonade)
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
	@test -x test.sh || { $(call error_msg,test.sh not found or not executable); exit 1; }
	@$(call color_msg,Running tests inside Docker container...)
	@$(call color_msg,  Image: $(IMAGE_NAME))
	@$(call color_msg,  Type:  $(TYPE))
	@mkdir -p tests/ 2>/dev/null
	@docker run --rm -it \
		$(SANDBOX_MOUNTS) \
		$(DOCKER_ELEVATED_FLAGS) \
	    -v ./tests:/tests:rw \
		-v $(CURDIR)/test.sh:/home/node/test.sh:ro \
		-u $$(id -u):$(SANDBOX_GID) \
		$(IMAGE_NAME) \
		/bin/bash /home/node/test.sh "${IMAGE:-$(IMAGE_NAME)}" "${TYPE:-full}" bare

# === Testing ===

validate: # Run all Makefile validation tests
	@bash tests/makefile-tests.sh

test-makefile: validate # Alias for validate target

# === Maintenance ===

clean: remove # Remove sandbox Docker images
	@docker image prune -f

remove: # Remove all sandbox image variants (tags and untagged)
	@for img in $(IMAGE_PATTERNS); do \
		docker rmi --force "$$img" 2>/dev/null || true; \
	done

package: # Create a zip archive with all files needed to build and test the image, named with version tag
	@zip -q "sandbox-$(IMAGE_TAG).zip" $(PACKED_FILES)
	@printf '%b%s%b: %s\n' '$(GREEN)' 'Created' '$(RESET)' '"sandbox-$(IMAGE_TAG).zip"'

# === Version Management ===

update-versions: # Update package.json + requirements.txt with latest versions
	@echo "Fetching latest versions from npm and updating package.json..."
	@node scripts/update-versions.js
	@echo ""
	@echo "Fetching latest versions from PyPI and updating requirements.txt..."
	@bash scripts/update-pip-versions.sh

check-versions: # Compare package.json + requirements.txt versions against registries
	@UP_TO_DATE=0 && \
	OUTDATED=0 && \
	echo "Checking package.json versions against npm..." && \
	_tmp=$$(mktemp) && \
	node scripts/check-versions.js > "$$_tmp" 2>&1 && \
	tail -n +1 "$$_tmp" | head -n -1 && \
	NPM_SUMMARY=$$(tail -1 "$$_tmp") && \
	rm -f "$$_tmp" && \
	UP_TO_DATE=$$(echo "$$NPM_SUMMARY" | awk '{print $$1}') && \
	OUTDATED=$$(echo "$$NPM_SUMMARY" | awk '{print $$2}') && \
	echo "" && \
	echo "Checking requirements.txt versions against PyPI..." && \
	_tmp2=$$(mktemp) && \
	bash scripts/check-pip-versions.sh > "$$_tmp2" 2>&1 || true && \
	tail -n +1 "$$_tmp2" | head -n -1 && \
	PIP_SUMMARY=$$(tail -1 "$$_tmp2") && \
	P_UP=$$(echo "$$PIP_SUMMARY" | awk '{print $$1}') && \
	P_OUT=$$(echo "$$PIP_SUMMARY" | awk '{print $$2}') && \
	UP_TO_DATE=$$((UP_TO_DATE + P_UP)) && \
	OUTDATED=$$((OUTDATED + P_OUT)) && \
	rm -f "$$_tmp2" && \
	echo "" && \
	echo "Summary: $$UP_TO_DATE up to date, $$OUTDATED out of date." && \
	exit $$OUTDATED
