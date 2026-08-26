#!/usr/bin/env bash
# Entrypoint for the OpenCode sandbox image.
# Applies runtime security policy, then execs the container command.

# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

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
