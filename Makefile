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
# Exception: make run-init shares ~/.config/opencode READ-WRITE ONCE, so that
# OpenCode can bootstrap its own configuration on a fresh machine. Regular
# runs keep it strictly read-only
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

# Host Docker access flags - used ONLY by run-insecure
# (Linux mounts docker binaries, macOS only mounts socket)
ifeq ($(IS_DARWIN),1)
DOCKER_INSECURE_FLAGS :=
else
DOCKER_INSECURE_FLAGS := --group-add docker -v /usr/bin/docker:/usr/bin/docker:ro -v /usr/libexec/docker:/usr/libexec/docker:ro -v /var/run/docker.sock:/var/run/docker.sock:ro
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
BUILDX_VERSION ?= 0.36.1
# SHA256 pins for build-time downloads (refresh together with the versions):
#   curl -fsSL <artifact-url> | sha256sum
ENGRAM_SHA256 ?= 7dc3003318e303bee269a4772144f3ce01c8ec700bfd524aaec76770acd389ca
BUILDX_SHA256_AMD64 ?= 48af8a397ebd60178778bf63611dbcebe5f5e7a9be90eb9147b24b9587455778
BUILDX_SHA256_ARM64 ?= 5d0cafd9d16afe1a0f0d9529885344ace2cc99efdd531b6c783c5455a6001569
TARGET ?= example.com

# Image tag defaults to "latest" for day-to-day builds. Override to tag
# with the release version or any custom tag:
#	make build					   → builds & tags as "latest"
#	make build IMAGE_TAG=$(OPENCODE_VERSION) → tags with the release version
#	make build IMAGE_TAG=abc1234   → tags with a commit/sha
IMAGE_TAG ?= latest

# Group for sandboxed runs
GROUP ?= $(shell id -gn)

# Docker group ID (falls back to 111 if docker group doesn't exist)
DOCKER_GID ?= $(shell getent group docker 2>/dev/null | cut -d: -f3 || echo 111)

# HOST_LEMONADE maps a hostname to an IP for local development
HOST_LEMONADE ?=

# Server configuration
SERVER_PORT ?= 5000
# Bind address for the published server port (use 0.0.0.0 to expose beyond localhost)
SERVER_BIND ?= 127.0.0.1
# Set to 1 to allow weak server credentials (password equals username, or 'changeme')
ALLOW_WEAK_SERVER_CREDENTIALS ?= 0

# Docker-in-Docker (rootless, private daemon — no host socket involved).
# Device flags can be overridden (e.g. set DIND_DEVICE_FLAGS= --device /dev/fuse
# on platforms without /dev/net/tun; the launcher then falls back to --net=host)
DIND_DEVICE_FLAGS ?= --device /dev/fuse --device /dev/net/tun
DIND_EXTRA_FLAGS ?=
# The engine's default seccomp profile blocks nested userns/mount primitives,
# so DIND runs relax the OUTER seccomp filter. Since Engine 25,
# no-new-privileges is also default-on, which neuters the setuid bit of
# newuidmap/newgidmap (multi-entry UID maps then fail with EPERM) — disabled
# for DIND runs as well. Compensating controls stay in place: no host Docker
# socket, namespaced daemon, non-root user.
DIND_SECURITY_FLAGS ?= --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt no-new-privileges=false

# Node.js TLS certificate verification inside the sandbox
# 1 (default) = enforce; 0 = INSECURE escape hatch (verification disabled)
STRICT_TLS ?= 1

# Detach key sequence for interactive containers. Docker's default
# (ctrl-p,ctrl-q) collides with the OpenCode TUI command palette (ctrl-p):
# the attach proxy swallows the keypress or detaches the TUI. ctrl-@ (NUL)
# is not used by any TUI; press it twice in quick succession to detach.
# Set DETACH_KEYS= to disable detaching entirely (recent engines only;
# Ctrl+C then exits the TUI, which ends the container).
DETACH_KEYS ?= ctrl-@,ctrl-@
# Flags shared by every interactive container run
INTERACTIVE_FLAGS := --rm -it --detach-keys=$(DETACH_KEYS)

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

define green_msg
printf '%b%b%b\n' '$(GREEN)' '$1' '$(RESET)'
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

# Create the .memory/ directory structure and placeholder session/prompt
# files. Fails loudly (no suppressed stderr) when directories or files cannot
# be created, or when existing entries are NOT usable by the invoking user.
# Writability (group access counts) is what SQLite and the session files need;
# .memory/dind must additionally be OWNED by the invoking user, because
# rootless dockerd chmods it and fails with EPERM otherwise. Leftovers from
# another account or CI run would break cryptically later without this guard.
define prepare_memory
for dir in .memory .memory/codebase-memory-mcp .memory/dind .memory/engram .memory/opencode; do \
	if ! mkdir -p "$$dir"; then \
		printf '%bERROR:%b Cannot create %s (check write access on %s)\n' '$(RED)' '$(RESET)' "$$dir" '$(CURDIR)'; \
		exit 1; \
	fi; \
done; \
unusable=""; \
for entry in .memory .memory/codebase-memory-mcp .memory/dind .memory/engram .memory/opencode \
	.memory/opencode/opencode.db .memory/opencode/opencode.db-shm .memory/opencode/opencode.db-wal .memory/opencode/prompt-history.jsonl; do \
	if [ -e "$$entry" ]; then \
		if [ ! -w "$$entry" ] || { [ "$$entry" = ".memory/dind" ] && [ ! -O "$$entry" ]; }; then \
			unusable="$$unusable $$entry"; \
		fi; \
	fi; \
done; \
if [ -n "$$unusable" ]; then \
	printf '%bERROR:%b .memory contains entries you cannot use (not writable, or .memory/dind not owned by you) (%s):\n' '$(RED)' '$(RESET)' "$$unusable"; \
	echo "       Fix once with:"; \
	echo "       sudo chown -R $$(id -u):$$(id -g) .memory && sudo chmod -R u+rwX .memory"; \
	exit 1; \
fi; \
if ! touch .memory/opencode/opencode.db .memory/opencode/opencode.db-shm .memory/opencode/opencode.db-wal .memory/opencode/prompt-history.jsonl; then \
	$(call error_msg,ERROR: Cannot create .memory/opencode session files (check write access on $(CURDIR))); \
	exit 1; \
fi
endef

# === Derived Variables ===

# Group ID for sandboxed runs
SANDBOX_GID := $(shell getent group $(GROUP) | cut -d: -f3)

# Base mounts always included in sandbox runs
SANDBOX_BASE_MOUNTS := -u $$(id -u):$(SANDBOX_GID) \
	-e OPENCODE_CONFIG_DIR=/home/node/.config/opencode \
	-e STRICT_TLS=$(STRICT_TLS) \
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
	-e STRICT_TLS=$(STRICT_TLS) \
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

# Initial bootstrap mounts (see run-init): identical to SANDBOX_BASE_MOUNTS,
# except that the OpenCode configuration directory is mounted READ-WRITE
SANDBOX_BASE_MOUNTS_INIT := -u $$(id -u):$(SANDBOX_GID) \
	-e OPENCODE_CONFIG_DIR=/home/node/.config/opencode \
	-e STRICT_TLS=$(STRICT_TLS) \
	-v $(PROJECT_ROOT)/.memory/codebase-memory-mcp/:/home/node/codebase-memory-mcp/:rw \
	-v $(PROJECT_ROOT)/.memory/engram/:/home/node/.engram/:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/prompt-history.jsonl:/home/node/.local/state/opencode/prompt-history.jsonl:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db:/home/node/.local/share/opencode/opencode.db:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-shm:/home/node/.local/share/opencode/opencode.db-shm:rw \
	-v $(PROJECT_ROOT)/.memory/opencode/opencode.db-wal:/home/node/.local/share/opencode/opencode.db-wal:rw \
	-v $(PROJECT_ROOT):/$(PROJECT_NAME):rw \
	-v ~/.config/opencode:/home/node/.config/opencode:rw \
	-w /$(PROJECT_NAME)

SANDBOX_MOUNTS_INIT := $(SANDBOX_BASE_MOUNTS_INIT) $(SANDBOX_OPTIONAL_MOUNTS)

# Used by run-init to enforce that it only bootstraps a FRESH configuration:
# a single seed opencode.json is allowed to exist, everything else means
# the configuration directory is already in use
HOST_CONFIG_SEED := $(HOME)/.config/opencode/opencode.json
HOST_CONFIG_EXTRA := $(filter-out $(HOST_CONFIG_SEED),$(wildcard $(HOME)/.config/opencode/*))

# Shared docker build arguments (non-npm packages and runtime config only)
DOCKER_BUILD_ARGS := \
	--build-arg ENGRAM_VERSION=$(ENGRAM_VERSION) \
	--build-arg ENGRAM_SHA256=$(ENGRAM_SHA256) \
	--build-arg BUILDX_VERSION=$(BUILDX_VERSION) \
	--build-arg BUILDX_SHA256_AMD64=$(BUILDX_SHA256_AMD64) \
	--build-arg BUILDX_SHA256_ARM64=$(BUILDX_SHA256_ARM64) \
	--build-arg USER_ID=$$(id -u) \
	--build-arg GROUP_ID=$(SANDBOX_GID) \
	--build-arg DOCKER_GROUP=$(DOCKER_GID)

# Isolated docker build context: only the exact build inputs are staged, so
# `docker build` never walks the workspace. Walking it would fail on entries
# owned by other UIDs (e.g. .memory/) even when they are .dockerignore'd,
# because the context sender still opens directories to inspect them.
# `override` makes the value immune to command-line reassignment: the rm
# guard below must never be able to target anything but this fixed path.
override BUILD_CONTEXT := .build-context
BUILD_CONTEXT_FILES := Dockerfile docker-entrypoint.sh dockerd-sandboxed.sh package.json requirements.txt .dockerignore

# Guarded removal of the staging directory: refuses ONLY unsafe values
# (empty, '.', '/'); a non-existent directory is a fine no-op for rm -rf.
define remove_build_context
	if [ -z "$(BUILD_CONTEXT)" ] || [ "$(BUILD_CONTEXT)" = "." ] || [ "$(BUILD_CONTEXT)" = "/" ]; then \
		printf '  refusing unsafe rm: BUILD_CONTEXT="%s" is not a safe path\n' '$(BUILD_CONTEXT)'; \
		exit 1; \
	fi; \
	rm -rf -- './$(BUILD_CONTEXT)'
endef

# Compare one pinned checksum against an upstream checksums.txt manifest.
# $1 = label, $2 = pinned sha256, $3 = manifest file, $4 = artifact filename.
# Handles goreleaser/sha256sum quirks: optional './' and binary-mode '*'.
define check_one_pin
	pin_line=$$(awk -v f="$4" '{ gsub(/^\*/,"",$$2); gsub(/^\.\//,"",$$2); if ($$2 == f) print $$1 }' "$3"); \
	if [ -z "$$pin_line" ]; then \
		$(call error_msg,  $1: artifact not found in manifest: $4); \
		exit 1; \
	fi; \
	if [ "$$pin_line" = "$2" ]; then \
		$(call green_msg,  $1: pin matches upstream); \
	else \
		printf '%b  $1: MISMATCH - pin=[$2] upstream=[%s]%b\n' "$(RED)" "$$pin_line" "$(RESET)"; \
		exit 1; \
	fi
endef

context: # Stage an isolated build context (internal helper for image/custom-image)
	@$(call warn_env_crlf)
	@$(call remove_build_context)
	@mkdir -p $(BUILD_CONTEXT)
	@cp $(BUILD_CONTEXT_FILES) $(BUILD_CONTEXT)/
	@if [ -e Dockerfile.custom ]; then cp Dockerfile.custom $(BUILD_CONTEXT)/; fi
	@for pem in *.pem; do \
		if [ -e "$$pem" ]; then cp -- "$$pem" $(BUILD_CONTEXT)/; fi; \
	done
	@if [ -d extra ]; then \
		cp -R extra $(BUILD_CONTEXT)/extra; \
	fi

# Shared docker image removal pattern
IMAGE_PATTERNS := $(IMAGE_NAME) $(IMAGE_NAME):* $(TEST_IMAGE_NAME) $(TEST_IMAGE_NAME):* $(CUSTOM_IMAGE_NAME) $(CUSTOM_IMAGE_NAME):*

# Files included in package archive
PACKED_FILES := env.example Dockerfile .dockerignore docker-entrypoint.sh dockerd-sandboxed.sh Makefile test.sh README.md package.json requirements.txt

# === .PHONY ===
.PHONY: help preflight preflight-run preflight-init preflight-insecure build run latest run-init run-ephemeral run-insecure bash clean image context custom-image check-pins run-dind run-tests run-servers server package update-versions check-versions tag-version validate test-makefile

# === Building ===

# Explicit default target: without this, make picks the FIRST target defined
# in this file (currently "context") as the default goal
.DEFAULT_GOAL := help

# Help first: This will be the default target
help: # Display useful commands
	@grep -E '^[a-zA-Z_-]+:.*\s+#\s' Makefile | \
	awk 'BEGIN {FS = ":.*?# "}; {printf "\033[1;33m%-20s\033[0m %s\n", $$1, $$2}'

preflight: # Check prerequisites before building
	@$(call bold_msg,Running preflight checks...)
	@$(call warn_env_crlf)
	@command -v docker >/dev/null 2>&1 || { $(call error_msg,ERROR: docker is not installed); exit 1; }
	@docker info >/dev/null 2>&1 || { $(call error_msg,ERROR: docker daemon is not running); exit 1; }
	@test -f Dockerfile || { $(call error_msg,ERROR: Dockerfile not found in $(CURDIR)); exit 1; }
	@test -d ~/.config/opencode || { $(call error_msg,ERROR: ~/.config/opencode directory not found (required for run)); exit 1; }
	@test -n "$(SANDBOX_GID)" || { $(call error_msg,ERROR: GROUP '$(GROUP)' does not resolve to a group ID (check .env and host groups)); exit 1; }
	@$(call status_msg,All preflight checks passed)

preflight-run: # Check prerequisites for run commands
	@$(call bold_msg,Running preflight checks for run...)
	@$(call warn_env_crlf)
	@test "$(CURDIR)" != "$(HOME)" || { $(call error_msg,ERROR: Cannot run from home directory ($(CURDIR)) — this would map your entire home into the sandbox); exit 1; }
	@test -d ~/.config/opencode || { $(call error_msg,ERROR: ~/.config/opencode directory not found (required for run)); exit 1; }
	@test -n "$(SANDBOX_GID)" || { $(call error_msg,ERROR: GROUP '$(GROUP)' does not resolve to a group ID (check .env and host groups)); exit 1; }
	@$(call prepare_memory)
	@$(call status_msg,All run preflight checks passed)

preflight-init: # Check prerequisites for the one-time initial bootstrap run
	@$(call bold_msg,Running preflight checks for initial run...)
	@$(call warn_env_crlf)
	@test "$(CURDIR)" != "$(HOME)" || { $(call error_msg,ERROR: Cannot run from home directory ($(CURDIR))); exit 1; }
	@mkdir -p ~/.config/opencode
	@$(call prepare_memory)
	@$(call status_msg,All initial-run preflight checks passed)

preflight-insecure: preflight-run # Additional checks before the INSECURE host-Docker run
	@$(call bold_msg,Running preflight checks for INSECURE mode...)
ifeq ($(IS_DARWIN),1)
	@test -f /usr/local/bin/docker || { $(call error_msg,ERROR: /usr/local/bin/docker not found (Docker Desktop required for INSECURE mode)); exit 1; }
else
	@test -f /usr/bin/docker || { $(call error_msg,ERROR: /usr/bin/docker not found (required for INSECURE mode)); exit 1; }
	@test -d /usr/libexec/docker || { $(call error_msg,ERROR: /usr/libexec/docker directory not found (required for INSECURE mode)); exit 1; }
endif
	@$(call status_msg,All INSECURE-mode preflight checks passed)

build: preflight image # Build a fresh OpenCode sandbox (with preflight check)

image: context # Build a fresh OpenCode sandbox (with preflight check)
	@$(call color_msg,Building image: $(IMAGE_NAME)...)
	@$(call color_msg,Build arguments:)
	@printf '  -> ENGRAM_VERSION: %s\n' '$(ENGRAM_VERSION)'
	@printf '  -> BUILDX_VERSION: %s\n' '$(BUILDX_VERSION)'
	@printf '  -> USER_ID: %s\n' '$(shell id -u)'
	@printf '  -> GROUP_ID: %s\n' '$(SANDBOX_GID)'
	@printf '  -> DOCKER_GROUP: %s\n' '$(DOCKER_GID)'
	@if docker build $(BUILD_CONTEXT) -t $(IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS); then \
		$(call remove_build_context); \
	else \
		printf '  Build failed - %s kept for inspection\n' '$(BUILD_CONTEXT)'; \
		exit 1; \
	fi

tag-version: # Tag the latest image with the opencode-ai version from package.json
	@docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(OPENCODE_VERSION)
	@$(call green_msg,Tagged $(IMAGE_NAME):latest → $(IMAGE_NAME):$(OPENCODE_VERSION))

custom-image: context # Build image from alternative Dockerfile with different name
	@test -f Dockerfile.custom || { $(call error_msg,ERROR: Dockerfile.custom not found); exit 1; }
	@$(call color_msg,Building image: $(CUSTOM_IMAGE_NAME)...)
	@if docker build -f $(BUILD_CONTEXT)/Dockerfile.custom $(BUILD_CONTEXT) -t $(CUSTOM_IMAGE_NAME) -t $(CUSTOM_IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_BUILD_ARGS); then \
		$(call remove_build_context); \
	else \
		printf '  Build failed - %s kept for inspection\n' '$(BUILD_CONTEXT)'; \
		exit 1; \
	fi

# === Running ===

TAG ?= $(IMAGE_TAG)

run: preflight-run # Run OpenCode sandboxed in the current directory
	@$(call color_msg,Running sandbox image:)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	@docker run $(INTERACTIVE_FLAGS) $(SANDBOX_MOUNTS) $(IMAGE_NAME):$(TAG)

run-ephemeral: # Run OpenCode sandboxed without .memory/ mappings (ephemeral)
	@$(call color_msg,Running ephemeral sandbox image:)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	docker run $(INTERACTIVE_FLAGS) $(SANDBOX_MOUNTS_EPHEMERAL) $(IMAGE_NAME):$(TAG)

latest: TAG = latest
latest: run # Run OpenCode sandboxed with latest tag

# Identical to run, except that the OpenCode configuration directory is
# mounted READ-WRITE (SANDBOX_MOUNTS_INIT) so OpenCode can bootstrap its own
# configuration on a fresh machine. A single seed opencode.json may be placed
# there in advance; any other content blocks it unless FORCE=1 is set
run-init: preflight-init # ONE-TIME initial run: mounts OpenCode config dir READ-WRITE to bootstrap it
	@test -z "$(HOST_CONFIG_EXTRA)" || [ "$(FORCE)" = "1" ] || { $(call error_msg,ERROR: $(HOME)/.config/opencode contains unexpected entries); echo "       Only a single seed opencode.json is allowed to pre-exist for a first run"; echo "       Remove other files - or re-run this target with FORCE=1 to keep them"; exit 1; }
	@$(call color_msg,Running initial sandbox run - OpenCode config directory is WRITABLE:)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	docker run $(INTERACTIVE_FLAGS) $(SANDBOX_MOUNTS_INIT) $(IMAGE_NAME):$(TAG)

bash: # Run a bash shell
	docker run $(INTERACTIVE_FLAGS) $(SANDBOX_MOUNTS) $(IMAGE_NAME):latest /bin/bash

# Check server credentials for known-weak values (overridable)
define check_server_credentials
if [ "$(ALLOW_WEAK_SERVER_CREDENTIALS)" != "1" ]; then \
	if [ "$(OPENCODE_SERVER_PASSWORD)" = "changeme" ] || [ "$(OPENCODE_SERVER_PASSWORD)" = "$(OPENCODE_SERVER_USERNAME)" ]; then \
		$(call error_msg,ERROR: refusing weak OPENCODE_SERVER_PASSWORD (equals username or 'changeme')); \
		echo "       Set a strong password in .env, or override with ALLOW_WEAK_SERVER_CREDENTIALS=1"; \
		exit 1; \
	fi; \
fi
endef

# Export credentials to recipe environments so the server target can pass
# them via --env-file (instead of leaking them on the docker CLI / process list)
export OPENCODE_SERVER_USERNAME
export OPENCODE_SERVER_PASSWORD

server: preflight-run # Run OpenCode server in the current directory
	@test -n "$(OPENCODE_SERVER_PASSWORD)" || { $(call error_msg,ERROR: OPENCODE_SERVER_PASSWORD must be set); exit 1; }
	@$(call check_server_credentials)
	@$(call color_msg,Running server in $(PROJECT_NAME) as $(OPENCODE_SERVER_USERNAME) on $(SERVER_BIND):$(SERVER_PORT))
	@$(call show_image_tag,$(IMAGE_TAG))
	@envfile="$$(mktemp)" \
	&& trap 'rm -f "$$envfile"' EXIT INT TERM \
	&& printf '%s=%s\n' "OPENCODE_SERVER_USERNAME" "$$OPENCODE_SERVER_USERNAME" > "$$envfile" \
	&& printf '%s=%s\n' "OPENCODE_SERVER_PASSWORD" "$$OPENCODE_SERVER_PASSWORD" >> "$$envfile" \
	&& chmod 600 "$$envfile" \
	&& docker run --init $(INTERACTIVE_FLAGS) \
		--env-file "$$envfile" \
		-p $(SERVER_BIND):$(SERVER_PORT):$(SERVER_PORT) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		/bin/bash -c "cd /$(PROJECT_NAME) && opencode serve --port $(SERVER_PORT) --hostname 0.0.0.0"

run-insecure: preflight-insecure # Run OpenCode sandboxed with FULL host Docker access: INSECURE - avoid, prefer run-dind
	@$(call show_lemonade)
	@docker run $(INTERACTIVE_FLAGS) \
		$(DOCKER_INSECURE_FLAGS) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME)

run-dind: preflight-run # Run OpenCode sandboxed with a private rootless Docker daemon (no host socket)
	@$(call bold_msg,Running sandbox with rootless Docker-in-Docker...)
	@$(call color_msg,The daemon is namespaced and cannot touch the host Docker instance)
	@$(call show_image_tag,$(TAG))
	@$(call show_lemonade)
	@docker run $(INTERACTIVE_FLAGS) \
		-e DIND=1 \
		-e DIND_DATA_ROOT=/$(PROJECT_NAME)/.memory/dind \
		$(DIND_DEVICE_FLAGS) \
		$(DIND_SECURITY_FLAGS) \
		$(DIND_EXTRA_FLAGS) \
		$(SANDBOX_MOUNTS) \
		$(IMAGE_NAME):$(TAG)

# DIND test runs get a private daemon and deliberately NO host Docker socket,
# proving the sandbox works without it. Test runs NEVER use the host daemon:
# there is no reason to perform an INSECURE host-Docker run just for testing.
DIND_TEST_FLAGS := $(if $(filter dind,$(TYPE)),-e DIND=1 -e DIND_DATA_ROOT=/$(PROJECT_NAME)/.memory/dind $(DIND_DEVICE_FLAGS) $(DIND_SECURITY_FLAGS))

run-tests: preflight-run # Run tests inside Docker container (make run-tests IMAGE=my-image TYPE=full)
	@test -x test.sh || { $(call error_msg,test.sh not found or not executable); exit 1; }
	@$(call color_msg,Running tests inside Docker container...)
	@$(call color_msg,  Image: $(IMAGE_NAME))
	@$(call color_msg,  Type:  $(TYPE))
	@$(call color_msg,  Skip e2e: $(or $(SKIP_E2E),no))
	@mkdir -p tests/ 2>/dev/null
	@export SKIP_E2E && docker run $(INTERACTIVE_FLAGS) \
		$(SANDBOX_MOUNTS_EPHEMERAL) \
		$(DIND_TEST_FLAGS) \
		-e SKIP_E2E=$${SKIP_E2E:-} \
	    -v $(CURDIR)/tests:/tests:rw \
		-v $(CURDIR)/test.sh:/home/node/test.sh:ro \
		-u $$(id -u):$(SANDBOX_GID) \
		$(IMAGE_NAME) \
		/bin/bash /home/node/test.sh "${IMAGE:-$(IMAGE_NAME)}" "${TYPE:-full}" bare

run-servers: preflight-run # Test LLM server connectivity from inside Docker container
	@test -x test.sh || { $(call error_msg,test.sh not found or not executable); exit 1; }
	@$(call color_msg,Testing LLM server connectivity inside Docker container...)
	@$(call color_msg,  Image: $(IMAGE_NAME))
	@mkdir -p tests/ 2>/dev/null
	@docker run $(INTERACTIVE_FLAGS) \
		$(SANDBOX_MOUNTS) \
	    -v $(CURDIR)/tests:/tests:rw \
		-v $(CURDIR)/test.sh:/home/node/test.sh:ro \
		-u $$(id -u):$(SANDBOX_GID) \
		$(IMAGE_NAME) \
		/bin/bash /home/node/test.sh "${IMAGE:-$(IMAGE_NAME)}" "servers" bare

# === Testing ===

validate: # Run all Makefile validation tests
	@bash tests/makefile-tests.sh

test-makefile: validate # Alias for validate target

# === Maintenance ===

clean: remove # Remove sandbox Docker images and leftover build contexts
	@$(call remove_build_context)
	-@docker image prune -f

remove: # Remove all sandbox image variants (tags and untagged)
	@for img in $(IMAGE_PATTERNS); do \
		docker rmi --force "$$img" 2>/dev/null || true; \
	done

package: # Create a zip archive with all files needed to build and test the image, named with version tag
	@zip -qr "sandbox-$(IMAGE_TAG).zip" $(PACKED_FILES) $(if $(wildcard extra),extra,) \
		-x '*__pycache__*' '*.pytest_cache*' '*.ruff_cache*' '*.egg-info*'
	@$(call status_msg,Created sandbox-$(IMAGE_TAG).zip)

# === Version Management ===

update-versions: # Update package.json + requirements.txt with latest versions
	@echo "Fetching latest versions from npm and updating package.json..."
	@node scripts/update-versions.js
	@echo ""
	@echo "Fetching latest versions from PyPI and updating requirements.txt..."
	@bash scripts/update-pip-versions.sh

# Warn when .env contains Windows (CRLF) line endings: make silently keeps
# the carriage return as part of each value, which corrupts version pins,
# checksums, URLs and flags. WSL2 round-trips through Windows editors cause
# this regularly.
define warn_env_crlf
	if [ -f .env ] && grep -q $$'\r' .env; then \
		printf '%bWARNING: .env contains Windows (CRLF) line endings - values carry trailing carriage returns and corrupt build args (versions, checksums).%b Fix with: dos2unix .env, or: sed -i "%s" .env\n' "$(YELLOW)" "$(RESET)" 's/\r$$//g'; \
	fi
endef

check-pins: # Verify download checksum pins against upstream manifests (needs network)
	@work=$$(mktemp -d); trap 'rm -rf $$work' EXIT INT TERM; \
	curl -fsSL "https://github.com/Gentleman-Programming/engram/releases/download/v$(ENGRAM_VERSION)/checksums.txt" -o $$work/engram.txt || exit 1; \
	curl -fsSL "https://github.com/docker/buildx/releases/download/v$(BUILDX_VERSION)/checksums.txt" -o $$work/buildx.txt || exit 1; \
	$(call check_one_pin,engram $(ENGRAM_VERSION) linux_amd64,$(ENGRAM_SHA256),$$work/engram.txt,engram_$(ENGRAM_VERSION)_linux_amd64.tar.gz); \
	$(call check_one_pin,buildx $(BUILDX_VERSION) amd64,$(BUILDX_SHA256_AMD64),$$work/buildx.txt,buildx-v$(BUILDX_VERSION).linux-amd64); \
	$(call check_one_pin,buildx $(BUILDX_VERSION) arm64,$(BUILDX_SHA256_ARM64),$$work/buildx.txt,buildx-v$(BUILDX_VERSION).linux-arm64); \
	$(call status_msg,All download pins match upstream manifests)

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
