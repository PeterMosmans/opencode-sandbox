#!/usr/bin/env bash
set -euo pipefail

# Test script for OpenCode sandbox Docker images

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# Usage: ./test.sh [IMAGE_NAME] [TEST_TYPE] [MODE]
#   IMAGE_NAME : Docker image to test (default: opencode-sandbox-$(id -u))
#   TEST_TYPE  : Which tests to run: linters, agent, full, updates (default: full)
#   MODE       : bare (run commands directly) or docker (wrap in docker run, default)
#
# Inside Docker (bare): make run-tests TYPE=full
# Locally (docker):     ./test.sh [IMAGE_NAME] [TYPE]

BOLD=$'\033[1m'
BLUE=$'\033[1;34m'
GREEN=$'\033[32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

IMAGE_NAME="${1:-opencode-sandbox-$(id -u)}"
TEST_TYPE="${2:-full}"
MODE="${3:-docker}"
HOST_PORT="${HOST_PORT:-8000}"
# which host to screenshot
TARGET="example.com"
# Pass along a GROUP
ID="$(id -u)"
GROUP="$(id -g --name)"
SANDBOX_GID="$(getent group "${GROUP}" | cut -d: -f3)"

usage() {
  echo "Usage: $0 [IMAGE_NAME] [TEST_TYPE] [MODE]"
  echo "  IMAGE_NAME : Docker image to test (default: opencode-sandbox-\$(id -u))"
  echo "  TEST_TYPE  : linters, agent, full, updates"
  echo "  MODE       : bare (run directly) or docker (wrap in docker run)"
  exit 1
}

info() { printf '%b%s%b\n' "$BLUE" "$1" "$RESET"; }
success() { printf '%b%s%b\n' "$GREEN" "$1" "$RESET"; }
error() { printf '%b%s%b\n' "$RED" "$1" "$RESET"; }

# Execute a command — bare mode runs directly, docker mode wraps in docker run
run_cmd() {
  if [ "$MODE" = "docker" ]; then
    docker run --rm -t -u "${ID}:${SANDBOX_GID}" "$IMAGE_NAME" "$@"
  else
    "$@"
  fi
}

test_linters() {
  info "Testing linters..."
  success "Version checks:"
  local ver

  ver="$(run_cmd shellcheck --version | grep -i version: | awk '{print $2}')"
  printf '  shellcheck %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd yamllint --version | sed 's/^yamllint //')"
  printf '  yamllint   %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd biome --version | sed 's/^Version: //')"
  printf '  biome      %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd htmlhint --version)"
  printf '  htmlhint   %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd prettier --version)"
  printf '  prettier   %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd ruff --version | awk '{print $2}')"
  printf '  ruff       %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd pre-commit --version)"
  printf '  pre-commit %b%s%b\n' "$BOLD" "$ver" "$RESET"
}

test_doctors() {
  info "Testing agent-browser doctor"
  run_cmd agent-browser doctor
  run_cmd engram doctor
  run_cmd bd doctor
}


test_agent() {
  info "Testing agent-browser tool"
  run_cmd rm -f ./tests/agent-${TARGET}.png 2>/dev/null || true
  info "Testing configuration"
  run_cmd agent-browser doctor
  run_cmd /bin/bash -c "agent-browser open https://${TARGET} && agent-browser screenshot ./tests/agent-${TARGET}.png"
  info "agent-browser screenshot generated"
  if [[ -f "./tests/agent-${TARGET}-correct.png" ]]; then
      info "Comparing results with ./tests/agent-${TARGET}-correct.png"
      diff "./tests/agent-${TARGET}-correct.png" "./tests/agent-${TARGET}.png"
  else
      mv "./tests/agent-${TARGET}.png" "tests/agent-${TARGET}-correct.png"
      info "First run of test - creating new screenshot (please verify manually)"
      info "Created tests/agent-${TARGET}-correct.png" 
  fi
  success "agent-browser successfully installed"
  run_cmd rm -f ./tests/agent-${TARGET}.png 2>/dev/null
}

test_playwright() {
  info "Testing Playwright MCP server:"
  run_cmd rm -f ./tests/playwright-${TARGET}.png 2>/dev/null || true
  run_cmd playwright install --list
  info "Testing OpenCode and Playwright MCP server to create a screenshot (this could take a while)"
  run_cmd opencode run use playwright mcp to create screenshot of "https://${TARGET}" and save it as ./tests/playwright-${TARGET}.png
  info "Playwright screenshot generated"
  if [[ -f "./tests/playwright-${TARGET}-correct.png" ]]; then
      info "Comparing results with ./tests/playwright-${TARGET}-correct.png"
      diff "./tests/playwright-${TARGET}-correct.png" "./tests/playwright-${TARGET}.png"
  else
      mv "./tests/playwright-${TARGET}.png" "tests/playwright-${TARGET}-correct.png"
      info "First run of test - creating new screenshot (please verify manually)"
      info "Created tests/playwright-${TARGET}-correct.png" 
  fi
  success "Playwright successfully installed"
  run_cmd rm -f ./tests/playwright-${TARGET}.png 2>/dev/null
}

test_base() {
  local versions=("opencode" "openspec")
  for cmd in "${versions[@]}"; do
    ver="$(run_cmd "$cmd" --version)"
    echo "running ${cmd} version: ${BOLD}${ver}${RESET}"
  done

  if [ -n "${HOST_NAME:-}" ]; then
    echo "Testing connection with ${HOST_NAME}"
    if [ "$MODE" = "docker" ]; then
      docker run --rm --entrypoint curl "$IMAGE_NAME" -I --cacert /etc/ssl/certs/"${HOST_NAME}".pem \
        "https://${HOST_NAME}:${HOST_PORT}/"
    else
      curl -I --cacert /etc/ssl/certs/"${HOST_NAME}".pem \
        "https://${HOST_NAME}:${HOST_PORT}/"
    fi
  fi

  if [ "$MODE" = "docker" ]; then
    docker run --rm --group-add docker \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      -v /usr/bin/docker:/usr/bin/docker:ro \
      --entrypoint /usr/bin/docker "$IMAGE_NAME" ps
  else
    docker ps
  fi
}

test_updates() {
  info "Checking for available npm package updates..."
  echo ""
  local npm_pkgs=(
    "@biomejs/biome"
    "@fission-ai/openspec"
    agent-browser
    commit-and-tag-version
    htmlhint
    opencode-ai
    openspec-mcp
    prettier
    "@prettier/plugin-xml"
    prettier-plugin-ini
    prettier-plugin-nginx
    prettier-plugin-sh
  )

  for pkg in "${npm_pkgs[@]}"; do
    local installed latest
    installed="$(run_cmd npm list -g "$pkg" 2> /dev/null | tail -2 | sed 's/.*@//')"
    latest="$(run_cmd npm view "$pkg" version 2> /dev/null)"
    if [ -n "$installed" ] && [ -n "$latest" ]; then
      if [ "$installed" != "$latest" ]; then
        printf '  %s: %b%s%b -> %b%s%b\n' "$pkg" "$YELLOW" "$installed" "$RESET" "$GREEN" "$latest" "$RESET"
      else
        printf '  %s: %b%s (up to date)%b\n' "$pkg" "$GREEN" "$installed" "$RESET"
      fi
    fi
  done

  info "Checking for available pip package updates..."
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue
    pkg_name="$(echo "$line" | cut -d= -f1)"
    installed="$(echo "$line" | cut -d= -f3)"
    { set +o pipefail; } 2> /dev/null || true
    latest="$(run_cmd pip3 index versions "$pkg_name" 2> /dev/null | head -1 | sed 's/.*(\(.*\))/\1/')"
    { set -o pipefail; } 2> /dev/null || true
    if [ -n "$installed" ] && [ -n "$latest" ]; then
      if [ "$installed" != "$latest" ]; then
        printf '  %s: %b%s%b -> %b%s%b\n' "$pkg_name" "$YELLOW" "$installed" "$RESET" "$GREEN" "$latest" "$RESET"
      else
        printf '  %s: %b%s (up to date)%b\n' "$pkg_name" "$GREEN" "$installed" "$RESET"
      fi
    fi
  done < requirements.txt
  echo ""
}

run_tests() {
  info "Running tests on image: ${BOLD}${IMAGE_NAME}${RESET}"
  echo ""
  info "Mode: ${BOLD}${MODE}${RESET}"
  echo ""
  info "Running under user ID ${ID} and group ID ${SANDBOX_GID}"
  run_cmd opencode --version
  run_cmd id
  test_doctors
  case "$TEST_TYPE" in
    browsers)
      test_agent
      test_playwright
      ;;
    linters) test_linters ;;
    updates) test_updates ;;
    full | all)
      test_base
      echo ""
      test_linters
      echo ""
      test_updates
      echo ""
      test_agent
      test_playwright
      ;;
    *)
      usage
      ;;
  esac

  success "All tests completed for ${IMAGE_NAME}"
}

trap 'echo -e "${RED}Test interrupted.${RESET}"' INT TERM

run_tests
