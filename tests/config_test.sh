#!/usr/bin/env bash
# Empty and malformed config files: drives.conf and users.conf parsing, and
# what /scan and /full report when no drives are configured.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
export BOT_POLLER_LIB_ONLY=1
export HOST_NAME="fixture-host"
export DRIVES_FILE="${tmpdir}/drives.conf"
export USERS_FILE="${tmpdir}/users.conf"
export STATE_FILE="${tmpdir}/state.json"
export STATE_LOCK="${tmpdir}/state.lock"
export TMPDIR="${tmpdir}/tmp"
mkdir -p "$TMPDIR" "${tmpdir}/api"
make_fake_smartctl "$tmpdir"
export SMARTCTL_BIN="${tmpdir}/smartctl"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/bot_poller.sh"
record_tg_api "${tmpdir}/api"
state_init

drives() {
    load_drives | paste -sd '|' -
}

# --- drives.conf -----------------------------------------------------------------
rm -f "$DRIVES_FILE"
assert_eq "$(drives)" "" "missing drives.conf"
: > "$DRIVES_FILE"
assert_eq "$(drives)" "" "empty drives.conf"
printf '# only comments\n   # indented comment\n\n\t\n' > "$DRIVES_FILE"
assert_eq "$(drives)" "" "comment-only drives.conf"
printf '\r\n\r\n' > "$DRIVES_FILE"
assert_eq "$(drives)" "" "CRLF blank lines"
assert_eq "$(DRIVES_FILE="$tmpdir" drives)" "" "drives.conf is a directory"

printf '%s\r\n' \
    "# header comment" \
    "  /dev/sda  " \
    $'\t/dev/sdb\t# backup disk' \
    "/dev/sda" \
    "/dev/disk/by-id/ata-Fixture_HDD_[A]*1" \
    "sdz" \
    "" > "$DRIVES_FILE"
assert_eq "$(drives)" "/dev/sda|/dev/sdb|/dev/disk/by-id/ata-Fixture_HDD_[A]*1|sdz" \
    "CRLF, padding, trailing comments and duplicates"

# A malformed entry is still checked, so the typo shows up as a finding rather
# than silently disappearing.
printf 'sdz\n' > "$DRIVES_FILE"
echo 1001 > "$USERS_FILE"
: > "${TG_RECORD_DIR}/calls.jsonl"
handle_command 1001 "/scan"
typo="$(tg_calls '.[1].fields.text')"
assert_contains "$typo" "🔴 sdz — CRITICAL" "malformed entry reported"
assert_contains "$typo" "smartctl_no_output" "malformed entry evidence"

# --- users.conf ---------------------------------------------------------------------
printf '  1001  \r\n# 2002\n\t3003\t# second admin\n' > "$USERS_FILE"
is_authorized 1001 || fail "padded CRLF chat id not authorized"
is_authorized 3003 || fail "chat id with trailing comment not authorized"
if is_authorized 2002; then fail "commented-out chat id authorized"; fi
if is_authorized 100; then fail "substring of a chat id authorized"; fi
: > "$USERS_FILE"
if is_authorized 1001; then fail "empty users.conf authorized a chat"; fi
rm -f "$USERS_FILE"
if is_authorized 1001; then fail "missing users.conf authorized a chat"; fi
assert_eq "$(tg_chat_ids | wc -l | tr -d ' ')" "0" "missing users.conf chat ids"

# --- No drives configured: never "healthy" -------------------------------------------
echo 1001 > "$USERS_FILE"
printf '# nothing here yet\n' > "$DRIVES_FILE"
: > "${TG_RECORD_DIR}/calls.jsonl"
: > "${tmpdir}/reads.log"
handle_command 1001 "/scan"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage" "/scan with no drives"
assert_eq "$(tg_calls '.[0].fields.text')" "🔍 Checking drives on fixture-host…" "/scan ack with no drives"
empty_report="$(tg_calls '.[1].fields.text')"
assert_contains "$empty_report" "No drives configured: nothing was checked." "/scan with no drives"
for word in GOOD healthy "🟢" "Worst:"; do
    assert_not_contains "$empty_report" "$word" "/scan with no drives claims health"
done

: > "${TG_RECORD_DIR}/calls.jsonl"
handle_command 1001 "/full"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage" "/full with no drives sends no attachment"
assert_contains "$(tg_calls '.[1].fields.text')" "No drives configured" "/full with no drives"
assert_eq "$(wc -l < "${tmpdir}/reads.log" | tr -d ' ')" "0" "smartctl called with no drives"
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "temp files left with no drives"

# --- Malformed state file is reset, heartbeat defaults to on ---------------------------
printf '{not json' > "$STATE_FILE"
state_init
assert_eq "$(jq -c . "$STATE_FILE")" "{}" "malformed state reset"
assert_eq "$(state_heartbeat_enabled)" "true" "heartbeat default after reset"

echo "config_test: ok"
