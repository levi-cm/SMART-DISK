#!/usr/bin/env bash
# state_lib.sh — sourced helpers for locked state mutations.
# Both entrypoint.sh and bot_poller.sh write the same JSON file; flock
# serializes read-modify-write to avoid lost updates.

STATE_FILE="${STATE_FILE:-/state/last_status.json}"
STATE_LOCK="${STATE_LOCK:-/state/.lock}"

state_init() {
    : > /dev/null
    (
        flock -x 9
        if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
            echo '{}' > "$STATE_FILE"
        fi
    ) 9>>"$STATE_LOCK"
}

# state_apply <jq_filter> [jq_args...]
# Applies filter under exclusive lock.
state_apply() {
    local filter="$1"; shift
    (
        flock -x 9
        local tmp
        tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
        if jq "$@" "$filter" "$STATE_FILE" > "$tmp"; then
            mv "$tmp" "$STATE_FILE"
        else
            rm -f "$tmp"
            return 1
        fi
    ) 9>>"$STATE_LOCK"
}

# state_read <jq_filter> [jq_args...]
# Reads under shared lock, prints raw output.
state_read() {
    local filter="$1"; shift
    (
        flock -s 9
        jq -r "$@" "$filter" "$STATE_FILE" 2>/dev/null
    ) 9>>"$STATE_LOCK"
}
