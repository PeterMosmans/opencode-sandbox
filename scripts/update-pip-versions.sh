#!/usr/bin/env bash
# Copyright (C) 2026 Peter Mosmans [Go Forward]
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

mapfile -t lines < requirements.txt
changed=0

for i in "${!lines[@]}"; do
    line="${lines[$i]}"
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue
    pkg_name=$(echo "$line" | cut -d= -f1)
    pkg_version=$(echo "$line" | cut -d= -f3)
    latest=$(pip index versions "$pkg_name" 2>/dev/null | head -1 | sed 's/.*(\(.*\))/\1/' || true)
    if [ -n "$latest" ]; then
        if [ "$pkg_version" != "$latest" ]; then
            echo "Updated: $pkg_name == $pkg_version -> $latest"
            lines[i]="${pkg_name}==$latest"
            changed=$((changed + 1))
        else
            echo "$pkg_name: up to date ($pkg_version)"
        fi
    else
        echo "Skipped: $pkg_name (could not fetch version)"
    fi
done

if [ "$changed" -gt 0 ]; then
    printf '%s\n' "${lines[@]}" > requirements.txt
    echo "Done. requirements.txt updated."
else
    echo "No pip packages need updating."
fi
