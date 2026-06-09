#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${STATE_FILE:-/state/last_status.json}"
STATE_LOCK="${STATE_LOCK:-/state/.lock}"

pgrep -f entrypoint.sh >/dev/null

state_dir="$(dirname "$STATE_FILE")"
[[ -d "$state_dir" ]]

(
    flock -n 9
    tmp="$(mktemp "${STATE_FILE}.healthcheck.XXXXXX")"
    rm -f "$tmp"
) 9>>"$STATE_LOCK"

jq -e . "$STATE_FILE" >/dev/null
