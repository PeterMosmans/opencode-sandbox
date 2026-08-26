#!/bin/sh
# Launches a rootless dockerd inside the sandbox (no host Docker socket).
# Mirrors the essential behavior of moby's dockerd-rootless.sh:
#   rootlesskit (user namespace + slirp4netns networking) -> dockerd
# Storage driver is auto-selected: fuse-overlayfs when /dev/fuse is
# available, otherwise the slower but dependency-free vfs fallback.

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
	echo "Usage: $0 --data-root DIR --runtime-dir DIR [--socket PATH] [--log FILE]" >&2
	exit 2
}

DATA_ROOT=""
RUNTIME_DIR=""
SOCKET=""
LOG_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--data-root) DATA_ROOT="$2"; shift 2 ;;
	--runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
	--socket) SOCKET="$2"; shift 2 ;;
	--log) LOG_FILE="$2"; shift 2 ;;
	*) usage ;;
	esac
done
if [ -z "$DATA_ROOT" ] || [ -z "$RUNTIME_DIR" ]; then usage; fi
[ -n "$LOG_FILE" ] || LOG_FILE="$RUNTIME_DIR/dockerd.log"

if [ "$(id -u)" = "0" ]; then
	echo "ERROR: rootless Docker must not run as root" >&2
	exit 1
fi
for bin in rootlesskit dockerd slirp4netns newuidmap; do
	if ! command -v "$bin" > /dev/null 2>&1; then
		echo "ERROR: required binary '$bin' not found" >&2
		exit 1
	fi
done

mkdir -p "$RUNTIME_DIR" "$DATA_ROOT"
chmod 700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

STATE_DIR="$RUNTIME_DIR/rootlesskit-state"
mkdir -p "$STATE_DIR"

[ -n "$SOCKET" ] || SOCKET="$RUNTIME_DIR/docker.sock"

STORAGE_DRIVER="vfs"
if [ -c /dev/fuse ] && command -v fuse-overlayfs > /dev/null 2>&1; then
	STORAGE_DRIVER="fuse-overlayfs"
fi

# Fail fast with actionable diagnostics when the host blocks the exact
# primitive rootlesskit needs (creating a user namespace), instead of
# letting the caller wait for a daemon that can never start.
if command -v unshare > /dev/null 2>&1; then
	if ! unshare -Ur true 2> /dev/null; then
		echo "ERROR: this host does not permit creating user namespaces." >&2
		echo "Rootless Docker needs unprivileged user namespaces. On the HOST, run:" >&2
		echo "  Debian family / WSL:  sudo sysctl -w kernel.unprivileged_userns_clone=1" >&2
		echo "  Ubuntu 24.04+:        sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" >&2
		exit 1
	fi
fi

# Network mode: slirp4netns needs a TAP device (/dev/net/tun). Without it,
# fall back to sharing the container's own network namespace — inner
# containers then see the same network as the sandbox, but no more.
if [ -c /dev/net/tun ]; then
	NET_ARGS="--net slirp4netns --disable-host-loopback --port-driver builtin"
else
	echo "NOTE: /dev/net/tun not available, using --net=host (container-scoped)"
	NET_ARGS="--net host --port-driver builtin"
fi

echo "Starting rootless dockerd (storage: $STORAGE_DRIVER)"
echo "  socket:     $SOCKET"
echo "  data-root:  $DATA_ROOT"
echo "  log:        $LOG_FILE"

# shellcheck disable=SC2086
rootlesskit \
	--state-dir "$STATE_DIR" \
	$NET_ARGS \
	--copy-up /etc \
	--copy-up /run \
	dockerd \
	--data-root "$DATA_ROOT" \
	--exec-root "$RUNTIME_DIR/exec-root" \
	--pidfile "$RUNTIME_DIR/dockerd.pid" \
	--host "unix://$SOCKET" \
	--storage-driver "$STORAGE_DRIVER" \
	${DIND_DAEMON_ARGS:-} \
	> "$LOG_FILE" 2>&1
