#!/usr/bin/env bash
# Heartbeat: an explicit "off" must hold (jq's // treated false as missing),
# and no heartbeat may be sent when no drives are configured.
# shellcheck disable=SC2317,SC2329 # tg_send/log stubs are called by the sourced entrypoint.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
export STATE_FILE="${tmpdir}/state.json"
export STATE_LOCK="${tmpdir}/state.lock"
export DRIVES_FILE="${tmpdir}/drives.conf"
export USERS_FILE="${tmpdir}/users.conf"
export HEARTBEAT_EVERY=1
export BURST_COUNT=1
export BURST_DELAY=0
echo 1001 > "$USERS_FILE"

cat > "${tmpdir}/smart_check" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == /dev/bad ]]; then
    echo "FAIL $1 severity=critical|Current_Pending_Sector(197)=2"
else
    echo "OK $1"
fi
SH
chmod +x "${tmpdir}/smart_check"
export SMART_CHECK_BIN="${tmpdir}/smart_check"

# scheduled_scan: one scan_once with the current files, in a subshell; prints
# every message it would have sent.
scheduled_scan() (
    export ENTRYPOINT_LIB_ONLY=1
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/scripts/entrypoint.sh"
    tg_send() { printf '%s\n' "$1"; }
    log() { :; }
    scan_once
)

# bot <command...>: runs bot_poller.sh functions in a subshell.
bot() (
    export BOT_POLLER_LIB_ONLY=1
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/scripts/bot_poller.sh"
    "$@"
)

# run_scan <state json> [drive...]: sets state and drives.conf, then scans.
run_scan() {
    printf '%s\n' "$1" > "$STATE_FILE"
    shift
    if (( $# > 0 )); then printf '%s\n' "$@" > "$DRIVES_FILE"; else : > "$DRIVES_FILE"; fi
    scheduled_scan
}

heartbeat="EVERYTHING AWESOME"

# Explicit false: the user turned it off.
out="$(run_scan '{"_meta":{"heartbeat_enabled":false}}' /dev/sda)"
assert_not_contains "$out" "$heartbeat" "heartbeat after the user disabled it"

# Explicit true and never set: on.
out="$(run_scan '{"_meta":{"heartbeat_enabled":true}}' /dev/sda)"
assert_contains "$out" "$heartbeat" "heartbeat when enabled"
out="$(run_scan '{}' /dev/sda /dev/sdb)"
assert_contains "$out" "$heartbeat" "heartbeat by default"
assert_contains "$out" "All 2 drives healthy." "heartbeat drive count"

# No drives: nothing was checked, so nothing is reported healthy.
out="$(run_scan '{}')"
assert_not_contains "$out" "$heartbeat" "heartbeat with an empty drives.conf"
assert_not_contains "$out" "healthy" "empty drives.conf reported healthy"
rm -f "$DRIVES_FILE"
out="$(scheduled_scan)"
assert_not_contains "$out" "$heartbeat" "heartbeat with no drives.conf at all"

# A non-OK drive still withholds the heartbeat (unchanged behaviour).
out="$(run_scan '{}' /dev/sda /dev/bad)"
assert_not_contains "$out" "$heartbeat" "heartbeat with a critical drive"
assert_contains "$out" "SMART CRITICAL" "critical alert still sent"

# The bot's toggle and status agree with what the scheduler does.
printf '{}\n' > "$STATE_FILE"
assert_eq "$(bot state_heartbeat_enabled)" "true" "bot default heartbeat state"
bot set_heartbeat_enabled false
assert_eq "$(bot state_heartbeat_enabled)" "false" "bot state after disabling"
assert_eq "$(jq -c '._meta.heartbeat_enabled' "$STATE_FILE")" "false" "stored heartbeat flag"
assert_contains "$(bot heartbeat_status_text)" "DISABLED" "bot status text after disabling"

# Round trip: disabled through the bot, so the scheduled scan stays quiet.
printf '/dev/sda\n' > "$DRIVES_FILE"
out="$(scheduled_scan)"
assert_not_contains "$out" "$heartbeat" "heartbeat after /heartbeat → Disable"
bot set_heartbeat_enabled true
assert_eq "$(bot state_heartbeat_enabled)" "true" "bot state after enabling"
assert_contains "$(scheduled_scan)" "$heartbeat" "heartbeat after /heartbeat → Enable"

echo "heartbeat_test: ok"
