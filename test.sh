#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Test tracking
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=""

# Test script for OpenCode sandbox Docker images

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# Usage: ./test.sh [IMAGE_NAME] [TEST_TYPE] [MODE]
#   IMAGE_NAME : Docker image to test (default: opencode-sandbox-$(id -u))
#   TEST_TYPE  : Which tests to run: linters, agent, browsers, full, updates, servers, all (default: full)
#   MODE       : bare (run commands directly) or docker (wrap in docker run, default)
#   TARGET     : Host to screenshot (default: example.com)
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
TARGET="${TARGET:-example.com}"
# CI color suppression
CI_COLORS=true
[[ ! -t 1 ]] && CI_COLORS=false
# Pass along a GROUP
ID="$(id -u)"
GROUP="$(id -g --name)"
SANDBOX_GID="$(getent group "${GROUP}" | cut -d: -f3)"

usage() {
  echo "Usage: $0 [IMAGE_NAME] [TEST_TYPE] [MODE]"
  echo "  IMAGE_NAME : Docker image to test (default: opencode-sandbox-\$(id -u))"
  echo "  TEST_TYPE  : linters, agent, browsers, full, updates, servers, all"
  echo "  MODE       : bare (run directly) or docker (wrap in docker run)"
  exit 1
}

info() {
  if [ "$CI_COLORS" = "true" ]; then
    printf '%b%s%b\n' "$BLUE" "$1" "$RESET"
  else
    printf '%s\n' "$1"
  fi
}
success() {
  if [ "$CI_COLORS" = "true" ]; then
    printf '%b%s%b\n' "$GREEN" "$1" "$RESET"
  else
    printf '%s\n' "$1"
  fi
}
error() {
  if [ "$CI_COLORS" = "true" ]; then
    printf '%b%s%b\n' "$RED" "$1" "$RESET"
  else
    printf '%s\n' "$1"
  fi
}

# Execute a command — bare mode runs directly, docker mode wraps in docker run
run_cmd() {
  if [ "$MODE" = "docker" ]; then
    docker run --rm -t -u "${ID}:${SANDBOX_GID}" "$IMAGE_NAME" "$@"
  else
    "$@"
  fi
}

# Execute a shell construct in Docker mode — wraps in bash -c
run_cmd_shell() {
  if [ "$MODE" = "docker" ]; then
    docker run --rm -t -u "${ID}:${SANDBOX_GID}" "$IMAGE_NAME" /bin/bash -c "$1"
  else
    /bin/bash -c "$1"
  fi
}

record_result() {
  local test_name="$1"
  local status="$2"
  local duration="$3"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ "$status" = "FAIL" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS="${FAILED_TESTS}${timestamp} - ${test_name} (${duration}s)\n"
  else
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

print_summary() {
  local status_symbol
  if [ "${CI_COLORS:-true}" = "true" ]; then
    status_symbol="${GREEN}"
  else
    status_symbol=""
  fi
  info "Test Summary:"
  if [ "${CI_COLORS:-true}" = "true" ]; then
    printf '%b%s%b | %b%s%b | %b%s%b\n' "$BOLD" "Test" "$RESET" "$BOLD" "Status" "$RESET" "$BOLD" "Duration" "$RESET"
    printf '%s | %s | %s\n' "$(printf '%0.s-' {1..30})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..10})"
  else
    printf '%-30s | %-10s | %s\n' "Test" "Status" "Duration"
    printf '%.0s-' {1..55}
    printf '\n'
  fi
  if [ -n "$TEST_ENTRIES" ]; then
    while IFS='|' read -r t_name t_status t_duration; do
      t_name="$(echo "$t_name" | xargs)"
      t_status="$(echo "$t_status" | xargs)"
      t_duration="$(echo "$t_duration" | xargs)"
      [ -z "$t_name" ] && continue
      if [ "$t_status" = "PASS" ]; then
        if [ "${CI_COLORS:-true}" = "true" ]; then
          printf '%b%s%b | %b%s%b | %s\n' "$RESET" "$t_name" "$RESET" "$status_symbol" "$t_status" "$RESET" "$t_duration"
        else
          printf '%-30s | %b%s%b | %s\n' "$t_name" "$status_symbol" "$t_status" "$RESET" "$t_duration"
        fi
      else
        if [ "${CI_COLORS:-true}" = "true" ]; then
          printf '%b%s%b | %b%s%b | %s\n' "$RESET" "$t_name" "$RESET" "$RED" "$t_status" "$RESET" "$t_duration"
        else
          printf '%-30s | %b%s%b | %s\n' "$t_name" "$RED" "$t_status" "$RESET" "$t_duration"
        fi
      fi
    done <<< "$(printf '%b' "$TEST_ENTRIES")"
  fi
  printf '\n'
  printf '%bTotal: %s passed, %s failed%b\n' "$BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$RESET"
  if [ -n "$FAILED_TESTS" ]; then
    printf '\nFailed tests:\n'
    printf '%b' "$FAILED_TESTS"
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

  ver="$(run_cmd pre-commit --version | awk '{print $2}')"
  printf '  pre-commit %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd jq --version 2> /dev/null | sed 's/^jq-//')"
  printf '  jq         %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd xmllint --version 2>&1 | grep -oP 'libxml version \K[0-9]+' || echo "unknown")"
  printf '  xmllint    %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd rg --version | head -1 | awk '{print $2}')"
  printf '  ripgrep    %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd tree --version | head -1 | awk '{print $2}' | sed 's/^v//')"
  printf '  tree       %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd fdfind --version 2> /dev/null | awk '{print $2}' || true)"
  if [ -z "$ver" ] || [ "$ver" = "not found" ]; then
    ver="$(run_cmd fd --version 2> /dev/null | head -1 | awk '{print $2}' || true)"
  fi
  [ -z "$ver" ] && ver="not found"
  printf '  fd-find    %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd pyright --version 2> /dev/null | awk '{print $2}' || true)"
  [ -z "$ver" ] && ver="not found"
  printf '  pyright    %b%s%b\n' "$BOLD" "$ver" "$RESET"

  ver="$(run_cmd playwright --version 2> /dev/null | awk '{print $2}' || true)"
  [ -z "$ver" ] && ver="not found"
  printf '  playwright %b%s%b\n' "$BOLD" "$ver" "$RESET"
}

test_doctors() {
  info "Testing agent-browser doctor"
  run_cmd agent-browser doctor
  run_cmd engram doctor
  run_cmd bd doctor
}

test_agent() {
  info "Testing agent-browser tool"
  run_cmd rm -f "./tests/agent-${TARGET}.png" 2> /dev/null || true
  run_cmd_shell "agent-browser open https://${TARGET} && agent-browser screenshot ./tests/agent-${TARGET}.png"
  info "agent-browser screenshot generated"
  if [[ -f "./tests/agent-${TARGET}-correct.png" ]]; then
    info "Comparing results with ./tests/agent-${TARGET}-correct.png"
    if run_cmd cmp -s "./tests/agent-${TARGET}.png" "./tests/agent-${TARGET}-correct.png"; then
      success "Screenshots are identical"
    else
      error "Screenshots differ from baseline"
      return 1
    fi
  else
    cp "./tests/agent-${TARGET}.png" "tests/agent-${TARGET}-correct.png"
    info "First run of test - creating new screenshot (please verify manually)"
    info "Created tests/agent-${TARGET}-correct.png"
  fi
  success "agent-browser successfully installed"
  run_cmd rm -f "./tests/agent-${TARGET}.png" 2> /dev/null
}

test_playwright() {
  info "Testing Playwright MCP server:"
  run_cmd rm -f "./tests/playwright-${TARGET}.png" 2> /dev/null || true
  run_cmd playwright install --list
  info "Testing OpenCode and Playwright MCP server to create a screenshot (this could take a while)"
  run_cmd opencode run use playwright mcp to create screenshot of "https://${TARGET}" and save it as "./tests/playwright-${TARGET}.png"
  info "Playwright screenshot generated"
  if [[ -f "./tests/playwright-${TARGET}-correct.png" ]]; then
    info "Comparing results with ./tests/playwright-${TARGET}-correct.png"
    if run_cmd cmp -s "./tests/playwright-${TARGET}.png" "./tests/playwright-${TARGET}-correct.png"; then
      success "Screenshots are identical"
    else
      error "Screenshots differ from baseline"
      return 1
    fi
  else
    cp "./tests/playwright-${TARGET}.png" "tests/playwright-${TARGET}-correct.png"
    info "First run of test - creating new screenshot (please verify manually)"
    info "Created tests/playwright-${TARGET}-correct.png"
  fi
  success "Playwright successfully installed"
  run_cmd rm -f "./tests/playwright-${TARGET}.png" 2> /dev/null
}

test_servers() {
  info "Testing LLM server connectivity..."

  # Resolve config file path entirely inside the container
  local config_file
  # shellcheck disable=SC2016
  config_file="$(run_cmd sh -c '
    f="${OPENCODE_CONFIG:-~/.config/opencode/opencode.json}"
    # Expand ~ only if present (quote ~ to prevent shell tilde expansion in pattern)
    case "$f" in
      "~"/*) f="${HOME}/${f#"~"/}" ;;
    esac
    echo "$f"
  ' 2> /dev/null)"

  # Fallback if run_cmd failed
  config_file="${config_file:-/home/node/.config/opencode/opencode.json}"

  if ! run_cmd test -f "$config_file"; then
    info "No opencode config found — skipping server tests"
    return 0
  fi

  local default_model
  default_model="$(run_cmd jq -r '.model // empty' "$config_file" 2> /dev/null)"
  if [ -z "$default_model" ]; then
    info "No default model set in config — testing all configured servers"
    default_model="all"
  fi

  # Build a list of all server URLs
  local all_urls
  all_urls="$(run_cmd jq -r '.provider | to_entries[] | "\(.key)|\(.value.options.baseURL)"' "$config_file" 2> /dev/null)"
  if [ -z "$all_urls" ]; then
    info "No server URLs found in config — skipping server tests"
    return 0
  fi

  # Determine required URLs (from .model) vs optional
  local required_urls=""
  if [ "$default_model" != "all" ]; then
    local provider_name model_name
    provider_name="${default_model%/*}"
    model_name="${default_model#*/}"
    # shellcheck disable=SC2016
    required_urls="$(run_cmd jq -r --arg provider "$provider_name" --arg model "$model_name" '
      .provider | to_entries[]
      | select(.key == $provider and .value.models[$model] != null)
      | "\(.key)|\(.value.options.baseURL)"
    ' "$config_file" 2> /dev/null)"
  fi

  local required_fail=0
  local optional_fail=0
  local total=0

  while IFS='|' read -r server_key server_url; do
    [ -z "$server_url" ] && continue
    total=$((total + 1))
    info "  Testing ${server_url}..."
    if run_cmd curl -sf --max-time 10 "$server_url" > /dev/null 2>&1; then
      success "    ${server_url} — reachable"
    else
      error "    ${server_url} — unreachable"
      if [ -n "$required_urls" ] && echo "$required_urls" | grep -qF "${server_key}|${server_url}"; then
        required_fail=$((required_fail + 1))
      else
        optional_fail=$((optional_fail + 1))
      fi
    fi
  done <<< "$all_urls"

  info "  ${total} server(s) checked: ${required_fail} required unreachable, ${optional_fail} optional unreachable"
  if [ "$required_fail" -gt 0 ]; then
    return 1
  fi
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
    if docker run --rm --group-add docker \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      -v /usr/bin/docker:/usr/bin/docker:ro \
      --entrypoint /usr/bin/docker "$IMAGE_NAME" ps 2> /dev/null; then
      success "Docker-in-Docker test passed"
    else
      info "Docker-in-Docker test skipped: socket not available or test failed"
    fi
  else
    if docker ps > /dev/null 2>&1; then
      success "Docker test passed"
    else
      info "Docker test skipped: docker not available"
    fi
  fi
}

test_updates() {
  info "Checking for available npm package updates..."
  echo ""
  local npm_pkgs=(
    "@biomejs/biome"
    "@fission-ai/openspec"
    "@opencode-ai/plugin"
    "@opencode-ai/sdk"
    "@playwright/mcp"
    "@beads/bd"
    agent-browser
    bash-language-server
    codebase-memory-mcp
    commit-and-tag-version
    htmlhint
    opencode-ai
    prettier
    "@prettier/plugin-xml"
    prettier-plugin-ini
    prettier-plugin-nginx
    prettier-plugin-sh
    prettier-plugin-toml
    stylelint
    webcrack
    yaml-language-server
  )

  for pkg in "${npm_pkgs[@]}"; do
    local installed latest
    installed="$(run_cmd npm list -g --depth=0 "$pkg" 2> /dev/null | grep -oP '@\K[0-9][^ )]+' | head -1 || true)"
    if [ -z "$installed" ]; then
      printf '  %s: %bnot installed%b\n' "$pkg" "$YELLOW" "$RESET"
      continue
    fi
    latest="$(run_cmd npm view "$pkg" version 2> /dev/null || true)"
    if [ -n "$installed" ] && [ -n "$latest" ]; then
      if [ "$installed" != "$latest" ]; then
        printf '  %s: %b%s%b -> %b%s%b\n' "$pkg" "$YELLOW" "$installed" "$RESET" "$GREEN" "$latest" "$RESET"
      else
        printf '  %s: %b%s (up to date)%b\n' "$pkg" "$GREEN" "$installed" "$RESET"
      fi
    fi
  done

  info "Checking for available pip package updates..."
  if [ "$MODE" = "docker" ]; then
    if ! run_cmd test -f requirements.txt 2> /dev/null; then
      info "requirements.txt not found in container - skipping pip update check"
      echo ""
      return 0
    fi
  fi
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

test_config() {
  info "Testing OpenCode configuration..."
  local config_file
  # shellcheck disable=SC2016
  config_file="$(run_cmd sh -c 'echo "${OPENCODE_CONFIG:-~/.config/opencode/opencode.json}"' 2> /dev/null || echo "")"
  config_file="${config_file:-~/.config/opencode/opencode.json}"
  # Resolve ~ to actual home
  config_file="${config_file/#\~/$HOME}"

  if run_cmd test -f "$config_file"; then
    success "Configuration file found: ${BOLD}${config_file}${RESET}"

    if run_cmd command -v jq > /dev/null 2>&1; then
      local model
      model="$(run_cmd jq -r '.model // "not set"' "$config_file" 2> /dev/null)"
      printf '  Default model: %b%s%b\n' "$BOLD" "$model" "$RESET"

      local providers
      providers="$(run_cmd jq -r '.provider // {} | keys[]' "$config_file" 2> /dev/null)"
      if [ -n "$providers" ]; then
        printf '  Providers:\n'
        while IFS= read -r provider; do
          local url
          url="$(run_cmd jq -r ".provider[\"${provider}\"].options.baseURL // \"not set\"" "$config_file" 2> /dev/null)"
          printf '    %b%s%b -> %s\n' "$BOLD" "$provider" "$RESET" "$url"
        done <<< "$providers"
      fi
    else
      error "jq not found — skipping config parsing"
    fi

    success "Configuration loaded successfully"
  else
    error "Configuration file not found: ${config_file}"
    error "OpenCode configuration is missing or inaccessible"
    return 1
  fi
}

validate_inputs() {
  # Validate IMAGE_NAME is a local Docker image
  if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
    error "Error: Image '${IMAGE_NAME}' not found locally"
    echo "Run 'docker pull ${IMAGE_NAME}' or build the image first."
    exit 1
  fi

  # Validate TEST_TYPE
  case "$TEST_TYPE" in
    linters | agent | browsers | full | updates | all | servers) ;;
    *)
      error "Error: Invalid TEST_TYPE '${TEST_TYPE}'"
      echo "Valid options: linters, agent, browsers, full, updates, servers, all"
      exit 1
      ;;
  esac

  # Validate MODE
  case "$MODE" in
    bare | docker) ;;
    *)
      error "Error: Invalid MODE '${MODE}'"
      echo "Valid options: bare, docker"
      exit 1
      ;;
  esac
}

run_tests() {
  info "Running tests on image: ${BOLD}${IMAGE_NAME}${RESET}"
  echo ""
  info "Mode: ${BOLD}${MODE}${RESET}"
  echo ""
  info "Running under user ID ${ID} and group ID ${SANDBOX_GID}"
  run_cmd opencode --version
  run_cmd id
  TEST_ENTRIES=""

  # Helper to wrap a test with timing and result recording
  # shellcheck disable=SC2317
  run_test() {
    local test_name="$1"
    shift
    local start_time
    start_time="$(date +%s)"
    if "$@"; then
      local end_time duration
      end_time="$(date +%s)"
      duration=$((end_time - start_time))
      record_result "$test_name" "PASS" "$duration"
      TEST_ENTRIES="${TEST_ENTRIES}${test_name}|PASS|${duration}s\n"
    else
      local end_time duration
      end_time="$(date +%s)"
      duration=$((end_time - start_time))
      record_result "$test_name" "FAIL" "$duration"
      TEST_ENTRIES="${TEST_ENTRIES}${test_name}|FAIL|${duration}s\n"
      error "Test '${test_name}' failed (exit code: $?, duration: ${duration}s)"
    fi
  }

  test_config
  echo ""

  # Track whether foundational tests passed — if config or servers fail,
  # skip everything that depends on them
  FOUNDATION_OK=true
  run_test() {
    local test_name="$1"
    shift
    local start_time
    start_time="$(date +%s)"
    if "$@"; then
      local end_time duration
      end_time="$(date +%s)"
      duration=$((end_time - start_time))
      record_result "$test_name" "PASS" "$duration"
      TEST_ENTRIES="${TEST_ENTRIES}${test_name}|PASS|${duration}s\n"
    else
      local end_time duration
      end_time="$(date +%s)"
      duration=$((end_time - start_time))
      record_result "$test_name" "FAIL" "$duration"
      TEST_ENTRIES="${TEST_ENTRIES}${test_name}|FAIL|${duration}s\n"
      error "Test '${test_name}' failed (exit code: $?, duration: ${duration}s)"
      FOUNDATION_OK=false
    fi
  }

  case "$TEST_TYPE" in
    browsers)
      if [ "$FOUNDATION_OK" = true ]; then
        run_test "base" test_base
      fi
      run_test "agent" test_agent
      run_test "playwright" test_playwright
      ;;
    linters) run_test "linters" test_linters ;;
    servers) run_test "servers" test_servers ;;
    updates) run_test "updates" test_updates ;;
    full | all)
      run_test "servers" test_servers
      echo ""
      if [ "$FOUNDATION_OK" = true ]; then
        run_test "base" test_base
        echo ""
        run_test "linters" test_linters
        echo ""
        run_test "updates" test_updates
        echo ""
        run_test "doctors" test_doctors
        echo ""
        run_test "agent" test_agent
        run_test "playwright" test_playwright
      fi
      ;;
    *)
      usage
      ;;
  esac

  print_summary
  success "All tests completed for ${IMAGE_NAME}"
}

trap 'echo -e "${RED}Test interrupted.${RESET}"; print_summary; exit 1' INT TERM

validate_inputs
run_tests
