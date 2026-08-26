#!/usr/bin/env bash
# Entrypoint for the OpenCode sandbox image.
# Applies runtime security policy, then execs the container command.

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

# Start a private rootless dockerd inside the sandbox when DIND=1.
# The daemon is namespaced (rootlesskit + slirp4netns) and has NO access
# to the host Docker socket: containers it runs can only reach this sandbox.
DIND_SOCKET=""
start_dind() {
	local runtime_dir data_root log_file waited
	DIND_SOCKET="${XDG_RUNTIME_DIR:-/tmp/dind}/docker.sock"
	runtime_dir="${XDG_RUNTIME_DIR:-/tmp/dind}"
	data_root="${DIND_DATA_ROOT:-$HOME/.local/share/docker-sandbox}"
	log_file="$runtime_dir/dockerd.log"

	if ! command -v dockerd > /dev/null 2>&1; then
		echo "ERROR: DIND=1 but docker.io is not installed in this image" >&2
		exit 1
	fi

	mkdir -p "$runtime_dir" "$data_root"
	# Rootless-in-container: /proc/sys is mounted read-only, so dockerd cannot
	# disable IPv6 router advertisement on interfaces; instruct it to tolerate
	# that instead of failing container startup.
	export DOCKER_ALLOW_IPV6_ON_IPV4_INTERFACE="${DOCKER_ALLOW_IPV6_ON_IPV4_INTERFACE:-1}"
	echo "Starting rootless Docker daemon (socket: $DIND_SOCKET, log: $log_file)"
	DIND_DAEMON_ARGS="${DIND_DAEMON_ARGS:-}" \
		/usr/local/bin/dockerd-sandboxed \
		--data-root "$data_root" \
		--runtime-dir "$runtime_dir" \
		--socket "$DIND_SOCKET" \
		--log "$log_file" &
	daemon_pid=$!
	waited=0
	until [ -S "$DIND_SOCKET" ] && docker --host "unix://$DIND_SOCKET" info > /dev/null 2>&1; do
		if ! kill -0 "$daemon_pid" 2> /dev/null; then
			echo "ERROR: rootless Docker daemon exited during startup" >&2
			if [ -f "$log_file" ]; then tail -n 40 "$log_file" >&2; fi
			exit 1
		fi
		waited=$((waited + 1))
		if [ "$waited" -ge "${DIND_START_TIMEOUT:-60}" ]; then
			echo "ERROR: rootless Docker daemon did not become ready within ${DIND_START_TIMEOUT:-60}s" >&2
			if [ -f "$log_file" ]; then tail -n 40 "$log_file" >&2; fi
			exit 1
		fi
		sleep 1
	done
	echo "Rootless Docker daemon is ready"
	return 0
}

if [ "${DIND:-0}" = "1" ]; then
	start_dind
	export DOCKER_HOST="unix://$DIND_SOCKET"
fi

# OpenCode does not fully support custom CAs yet (upstream limitation).
# Custom CA certificates ARE installed in the system trust store at build time,
# so curl, git and Python tools verify certificates regardless.
#
# STRICT_TLS=1  enforce Node.js certificate verification (future-proofing)
# STRICT_TLS=0  disable Node.js verification (default, required by OpenCode)
if [ "${STRICT_TLS:-0}" = "1" ]; then
	unset NODE_TLS_REJECT_UNAUTHORIZED
else
	printf '%s\n' \
		"WARNING: Node.js TLS certificate verification is DISABLED (STRICT_TLS=0)." \
		"         This is a temporary workaround until OpenCode supports custom CAs." >&2
	export NODE_TLS_REJECT_UNAUTHORIZED=0
fi

exec "$@"
