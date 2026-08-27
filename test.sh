#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Test tracking
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=""
TEST_ENTRIES=""

# Test script for OpenCode sandbox Docker images

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

# Usage: ./test.sh [IMAGE_NAME] [TEST_TYPE] [MODE]
#   IMAGE_NAME : Docker image to test (default: opencode-sandbox-$(id -u))
#   TEST_TYPE  : Chain to run (see CHAINS below; default: full)
#   MODE       : bare (run commands directly) or docker (wrap in docker run, default)
#   TARGET     : Host to screenshot (default: example.com)
#
# There are three test chains:
#
#   full    The complete tiered chain, ordered cheap -> expensive. It stops
#           where continuing makes no sense; e2e steps are gated on their
#           dependencies (config, servers, doctors) having PASSED earlier:
#             T1 static      config, versions, linters
#             T2 local infra doctors, host-endpoint, dind
#             T3 LLM gate    server reachability (required providers)
#             T4 tool E2E    agent-browser screenshot vs baseline
#             T5 agent E2E   playwright screenshot via opencode run
#             advisory last  package updates (informational)
#   dind    Only the rootless Docker-in-Docker test. The private daemon is
#           started automatically for you via make; never touches the host.
#   updates npm/pip update check only (advisory, informational).
#
# Skipped steps are listed with a reason; the exit code reflects failures.
#
# Inside Docker (bare): make run-tests TYPE=full
#                       make run-tests TYPE=dind
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
# CI color suppression: defaults to TTY detection; a CI_COLORS value already
# present in the environment (true|false) always wins
if [ -z "${CI_COLORS:-}" ]; then
  CI_COLORS=true
  [[ ! -t 1 ]] && CI_COLORS=false
fi
# Pass along a GROUP
ID="$(id -u)"
GROUP="$(id -g --name)"
SANDBOX_GID="$(getent group "${GROUP}" | cut -d: -f3)"

usage() {
  echo "Usage: $0 [IMAGE_NAME] [TEST_TYPE] [MODE]"
  echo "  IMAGE_NAME : Docker image to test (default: opencode-sandbox-\$(id -u))"
  echo "  TEST_TYPE  : full (default) | dind | updates"
  echo "               full    = T1 static -> T2 local infra -> T3 LLM gate"
  echo "                       -> T4/T5 end-to-end agents -> updates (advisory)"
  echo "               dind    = rootless Docker-in-Docker test only"
  echo "                       (make sets up the private daemon automatically)"
  echo "               updates = npm/pip package update check only"
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

# === Test dependency tracking ===
#
# STATE mirrors the outcome of gate-providing steps (config, servers,
# doctors): true on PASS, anything else means the step did not prove itself.
# Steps declare which states they depend on; unmet dependencies are SKIPPED
# with a reason instead of being run pointlessly.
#
# Skipping semantics: a step that returns success *without* exercising its
# subject (e.g. servers skips when no config exists) intentionally leaves its
# state false — downstream steps stay skipped, which is the honest outcome.

declare -A STATE

# Map a state key to an outcome: ["$key"]-style access needs quoting care
is_state_true() {
  [[ "${STATE[$1]:-false}" == "true" ]]
}

# Update a state key based on a test result (0 = pass)
set_state() {
  local key="$1"
  local status="$2"
  if [ "$status" -eq 0 ]; then
    STATE[$key]="true"
  else
    STATE[$key]="false"
  fi
}

# Check that all listed dependencies have passed; echo missing keys otherwise
missing_dependencies() {
  local dep
  for dep in $1; do
    is_state_true "$dep" || printf '%s ' "$dep"
  done
}

# Run a single test with timing and result recording.
#
# Return-code protocol: 0 = PASS, any nonzero = FAIL, 2 = SKIP. Tests that
# legitimately cannot exercise their subject (e.g. servers without config)
# set SKIP_NOTE before returning 2; their step is then recorded as SKIP so a
# vacuous pass can never satisfy a dependency gate. Returns the test's own
# status; callers needing the outcome inspect $? — dispatchers use step().
run_test() {
  local test_name="$1"
  shift
  local start_time end_time duration rc
  SKIP_NOTE=""
  start_time="$(date +%s)"
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  end_time="$(date +%s)"
  duration=$((end_time - start_time))
  local skip_note="${SKIP_NOTE:-}"
  if [ "$rc" -eq 0 ]; then
    record_result "$test_name" "PASS" "${duration}"
  elif [ "$rc" -eq 2 ] && [ -n "$skip_note" ]; then
    info "Skipping '${test_name}': ${skip_note}"
    record_result "$test_name" "SKIP" "${duration}" "${skip_note}"
  else
    record_result "$test_name" "FAIL" "${duration}"
    error "Test '${test_name}' failed (exit code: ${rc}, duration: ${duration}s)"
  fi
  return "$rc"
}

# Run one suite step, gated on its declared dependencies:
#   step <name> "<space-separated dep keys>" <function>
#
# Sets STATE[<name>] to true only on a real PASS; FAIL *and* SKIP leave it
# false. Always returns 0, so dispatchers can call it plainly under set -e.
step() {
  local name="$1"
  local deps="$2"
  shift 2
  local missing
  missing="$(missing_dependencies "$deps")"
  if [ -n "$missing" ]; then
    info "Skipping '${name}': dependency not met (${missing% })"
    record_result "$name" "SKIP" 0 "dependency not met: ${missing% }"
    STATE[$name]="false"
    return 0
  fi
  local rc=0
  run_test "$name" "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    STATE[$name]="true"
  else
    STATE[$name]="false"
  fi
  return 0
}

record_result() {
  local test_name="$1"
  local status="$2"
  local duration="$3"
  local note="${4:-}"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$status" in
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_TESTS="${FAILED_TESTS}${timestamp} - ${test_name} (${duration}s)\n"
      ;;
    SKIP)
      SKIP_COUNT=$((SKIP_COUNT + 1))
      ;;
    *)
      status="PASS"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
  esac
  # Single place that owns the summary table rows; duration is raw seconds
  if [ -n "$note" ] && [ "$status" != "PASS" ]; then
    TEST_ENTRIES="${TEST_ENTRIES}${test_name}|${status}|${duration}s|${note}\n"
  else
    TEST_ENTRIES="${TEST_ENTRIES}${test_name}|${status}|${duration}s|\n"
  fi
}

# === Summary table ===
#
# The table renders through ONE code path: cells are padded to the widest
# content in their column FIRST, then (only when CI_COLORS is on) wrapped in
# escape codes — escape sequences inside printf field widths would otherwise
# break alignment.

# Print text left-justified to a width, optionally color-wrapped AFTER padding
emit_cell() {
  local width="$1"
  local text="$2"
  local color="${3:-}"
  local padded
  padded="$(printf '%-*s' "$width" "$text")"
  if [ "${CI_COLORS}" = "true" ] && [ -n "$color" ]; then
    printf '%s' "${color}${padded}${RESET}"
  else
    printf '%s' "$padded"
  fi
}

status_color_for() {
  case "$1" in
    PASS) printf '%s' "$GREEN" ;;
    FAIL) printf '%s' "$RED" ;;
    SKIP) printf '%s' "$YELLOW" ;;
  esac
}

print_summary() {
  info "Test Summary:"

  # Pass 1: collect rows and size each column to its widest cell
  local -a names=() statuses=() durations=() notes=()
  local t_name t_status t_duration t_note
  while IFS='|' read -r t_name t_status t_duration t_note; do
    t_name="${t_name//[$'\t\r ']/}"
    [ -z "$t_name" ] && continue
    names+=("$t_name")
    statuses+=("${t_status//[$'\t\r ']/}")
    durations+=("${t_duration//[$'\t\r ']/}")
    notes+=("${t_note:-}")
  done <<< "$(printf '%b' "$TEST_ENTRIES")"

  local HEADER_TEST="Test" HEADER_STATUS="Status" HEADER_DURATION="Duration" HEADER_NOTES="Notes"
  local count=${#names[@]}
  local w_n=6 w_s=7 w_d=9 w_note=6
  local i len
  for ((i = 0; i < count; i++)); do
    len=${#names[$i]} ;        [ "$len" -gt "$w_n" ] && w_n=$len
    len=${#statuses[$i]} ;     [ "$len" -gt "$w_s" ] && w_s=$len
    len=${#durations[$i]} ;    [ "$len" -gt "$w_d" ] && w_d=$len
    len=${#notes[$i]} ;        [ "$len" -gt "$w_note" ] && w_note=$len
  done
  [ "${#HEADER_TEST}" -gt "$w_n" ] && w_n=${#HEADER_TEST}
  [ "${#HEADER_STATUS}" -gt "$w_s" ] && w_s=${#HEADER_STATUS}
  [ "${#HEADER_DURATION}" -gt "$w_d" ] && w_d=${#HEADER_DURATION}
  [ "${#HEADER_NOTES}" -gt "$w_note" ] && w_note=${#HEADER_NOTES}

  print_rule() {
    local total=$((w_n + w_s + w_d + w_note + 9))
    printf '%*s\n' "$total" '' | tr ' ' '-'
  }

  emit_row() {
    emit_cell "$w_n" "$1";                 printf ' | '
    emit_cell "$w_s" "$2" "$3";            printf ' | '
    emit_cell "$w_d" "$4";                 printf ' | '
    emit_cell "$w_note" "$5" "$6"
    printf '\n'
  }

  if [ "$count" -eq 0 ]; then
    info "  (no test results recorded)"
    return 0
  fi

  print_rule
  emit_row "$HEADER_TEST" "$HEADER_STATUS" "$BOLD" "$HEADER_DURATION" "$HEADER_NOTES" "$BOLD"
  print_rule
  for ((i = 0; i < count; i++)); do
    emit_row "${names[$i]}" "${statuses[$i]}" "$(status_color_for "${statuses[$i]}")" \
      "${durations[$i]}" "${notes[$i]}" ""
  done
  print_rule
  printf '\n'
  if [ "${CI_COLORS}" = "true" ]; then
    printf '%bTotal: %s passed, %s failed, %s skipped%b\n' "$BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RESET"
  else
    printf 'Total: %s passed, %s failed, %s skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  fi
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

test_dind() {
  info "Testing rootless Docker-in-Docker..."
  if [ "${DIND:-0}" != "1" ]; then
    SKIP_NOTE="no rootless Docker daemon started (via make: TYPE=dind starts one automatically)"
    return 2
  fi
  if ! run_cmd docker info > /dev/null 2>&1; then
    error "rootless dockerd is not reachable (DOCKER_HOST=${DOCKER_HOST:-unset})"
    return 1
  fi
  success "rootless dockerd is reachable"
  # Functional smoke test: build and run a tiny image entirely inside the sandbox daemon
  if ! run_cmd_shell 'printf "FROM busybox\nCMD [\"echo\", \"inner-container-ok\"]\n" | docker build -q -t dind-smoke-test - > /dev/null && docker run --rm dind-smoke-test | grep -q inner-container-ok'; then
    error "building/running a container inside the sandbox failed"
    return 1
  fi
  success "inner build/run works"
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
    SKIP_NOTE="no OpenCode config"
    return 2
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
    SKIP_NOTE="no provider URLs in config"
    return 2
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
    local http_code
    http_code="$(run_cmd curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$server_url" 2> /dev/null || true)"
    # Any HTTP response proves DNS/TLS/TCP connectivity: provider root paths
    # answer with anything from 200 over 401/403 to 404/405 depending on the
    # service — only a missing response (000) means truly unreachable
    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
      success "    ${server_url} — reachable (HTTP ${http_code})"
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

# T1: quick local sanity — the binaries the sandbox is all about
test_versions() {
  local cmd
  for cmd in opencode openspec; do
    ver="$(run_cmd "$cmd" --version)"
    echo "running ${cmd} version: ${BOLD}${ver}${RESET}"
  done
}

# T2: optional end-to-end TLS check against a host-provided endpoint.
# Independent of everything else; failure here does not gate other steps.
# NOTE: intentionally does NOT touch any Docker socket — the sandbox must be
# tested through its rootless DinD path only (see test_dind)
test_host_endpoint() {
  if [ -z "${HOST_NAME:-}" ]; then
    SKIP_NOTE="no HOST_NAME endpoint configured"
    return 2
  fi

  echo "Testing connection with ${HOST_NAME}"
  # Custom CAs are installed in the system trust store, so no --cacert needed
  if [ "$MODE" = "docker" ]; then
    docker run --rm --entrypoint curl "$IMAGE_NAME" -I \
      "https://${HOST_NAME}:${HOST_PORT}/"
  else
    curl -I \
      "https://${HOST_NAME}:${HOST_PORT}/"
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
  # Only docker MODE spawns containers itself, so only then must the image
  # exist locally. In bare mode the script typically runs INSIDE the image
  # under test — the outer 'docker run' proves its existence, and the sandbox
  # deliberately has no Docker daemon access (tests never need one; see
  # test_dind for the self-contained rootless exception)
  if [ "$MODE" = "docker" ]; then
    if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
      error "Error: Image '${IMAGE_NAME}' not found locally"
      echo "Run 'docker pull ${IMAGE_NAME}' or build the image first."
      exit 1
    fi
  fi

  # Validate TEST_TYPE: three chains, no aliases
  case "$TEST_TYPE" in
    full | dind | updates) ;;
    *)
      error "Error: Invalid TEST_TYPE '${TEST_TYPE}'"
      usage
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

# === Test chains ===
#
# TEST_TYPE exposes exactly three chains: full, dind and updates. The tiered
# suite_* builders below are internal to the `full` chain: every step uses the
# same step() definitions; dependencies reference state keys set earlier in
# the SAME run (config/servers/doctors); unmet dependencies are recorded as
# SKIP instead of failing.

# T1 (internal): static, local-only checks (seconds)
suite_smoke() {
  step config "" test_config
  echo ""
  step versions "" test_versions
  echo ""
  step linters "" test_linters
}

# T2: local infrastructure self-checks; independent of T1 outcomes
suite_tools() {
  step doctors "" test_doctors
  echo ""
  step host-endpoint "" test_host_endpoint
  echo ""
  step dind "" test_dind
}

# T3: LLM server reachability — the gate for anything end-to-end
suite_llm() {
  step servers "" test_servers
}

# T4/T5: heavyweight end-to-end agent tests, behind all gates
suite_e2e() {
  step agent "config servers doctors" test_agent
  step playwright "config servers doctors" test_playwright
}

run_tests() {
  info "Running tests on image: ${BOLD}${IMAGE_NAME}${RESET}"
  echo ""
  info "Mode: ${BOLD}${MODE}${RESET}"
  echo ""
  info "Running under user ID ${ID} and group ID ${SANDBOX_GID}"
  echo ""

  case "$TEST_TYPE" in
    updates)
      step updates "" test_updates
      ;;
    dind)
      step dind "" test_dind
      ;;
    full)
      suite_smoke
      echo ""
      suite_tools
      echo ""
      suite_llm
      echo ""
      suite_e2e
      echo ""
      # Advisory: informational checks run last and never gate anything
      step updates "" test_updates
      ;;
    *)
      usage
      ;;
  esac
}

finalize() {
  print_summary
  if [ "$FAIL_COUNT" -gt 0 ]; then
    error "Test suite finished with ${FAIL_COUNT} failure(s)"
    exit 1
  fi
  success "All tests completed successfully for ${IMAGE_NAME}"
}

trap 'echo -e "${RED}Test interrupted.${RESET}"; print_summary; exit 1' INT TERM

validate_inputs
run_tests
finalize
