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

	# Rootlesskit's newuidmap refuses to map a process whose gid differs from
	# the primary group of the user in /etc/passwd. The image bakes GROUP_ID
	# (host primary group at BUILD time) into /etc/passwd; if the host group
	# changed since, the runtime gid no longer matches and startup would fail
	# with a cryptic newuidmap error. Fail early with the remedy instead.
	local pw_gid
	# || true: getent exits non-zero for unknown uids, which set -e + pipefail
	# would otherwise turn into a silent failure before the check below runs
	pw_gid="$(getent passwd "$(id -u)" | cut -d: -f4 || true)"
	if [ -z "$pw_gid" ]; then
		echo "ERROR: runtime uid $(id -u) not found in /etc/passwd - rootless Docker-in-Docker cannot start" >&2
		echo "       Rebuild the image with: make build" >&2
		exit 1
	fi
	if [ "$pw_gid" != "$(id -g)" ]; then
		printf 'ERROR: image primary group for uid %s is %s, but the container runs with gid %s\n' \
			"$(id -u)" "$pw_gid" "$(id -g)" >&2
		echo "       Rootless Docker-in-Docker requires both to match." >&2
		echo "       The image was built with a different GROUP_ID (did your host primary group change?)." >&2
		echo "       Rebuild the image so it matches your current group: make build" >&2
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

# TLS policy is applied at runtime:
#   STRICT_TLS=1 (default): Node.js certificate verification stays ENABLED.
#     The system CA bundle (which includes custom CAs installed at build
#     time) is offered to Node via NODE_EXTRA_CA_CERTS, so private CAs keep
#     working without weakening anything. curl, git and Python tools verify
#     against the same system store regardless.
#   STRICT_TLS=0: INSECURE - disables Node.js verification entirely, making
#     connections inside the sandbox interceptable. Escape hatch only.
STRICT_TLS="${STRICT_TLS:-1}"
case "$STRICT_TLS" in
1 | 0) ;;
*)
	printf "WARNING: unknown STRICT_TLS value '%s' - falling back to secure mode (1)\n" "$STRICT_TLS" >&2
	STRICT_TLS=1
	;;
esac

# Offer the system CA bundle to Node (inert when verification is disabled).
# A NODE_EXTRA_CA_CERTS preset from the environment always wins.
export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-/etc/ssl/certs/ca-certificates.crt}"

if [ "$STRICT_TLS" = "1" ]; then
	# Fail-safe: never let a leaked NODE_TLS_REJECT_UNAUTHORIZED=0 disable
	# verification in secure mode
	unset NODE_TLS_REJECT_UNAUTHORIZED
else
	printf '%s\n' \
		"WARNING (INSECURE): Node.js TLS certificate verification is DISABLED (STRICT_TLS=0)." \
		"         Connections inside the sandbox can be intercepted. Use STRICT_TLS=1 to enforce verification." >&2
	export NODE_TLS_REJECT_UNAUTHORIZED=0
fi

exec "$@"
