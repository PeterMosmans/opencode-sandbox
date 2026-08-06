#!/usr/bin/env bash
set -euo pipefail

up_to_date=0
outdated=0
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue
    pkg_name=$(echo "$line" | cut -d= -f1)
    pkg_version=$(echo "$line" | cut -d= -f3)
    latest=$(pip index versions "$pkg_name" 2>/dev/null | head -1 | sed 's/.*(\(.*\))/\1/' || true)
    if [ -n "$latest" ]; then
        if [ "$pkg_version" != "$latest" ]; then
            echo "$pkg_name: $pkg_version -> $latest"
            outdated=$((outdated + 1))
        else
            echo "$pkg_name: up to date ($pkg_version)"
            up_to_date=$((up_to_date + 1))
        fi
    else
        echo "$pkg_name: could not fetch latest version (skipping)"
    fi
done < requirements.txt

echo "$up_to_date $outdated"
exit "$outdated"
