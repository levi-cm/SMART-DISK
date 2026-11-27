#!/usr/bin/env bash
# /scan and /full end to end inside bot_poller.sh, with the Bot API recorded:
# message counts, plain text, one smartctl read per drive (verdict, card and
# attachment agree), the attachment's content, temp-file cleanup, and the
# shared command list behind /help and setMyCommands.
# shellcheck disable=SC2016 # Backticks are literal Markdown in the attachment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
export BOT_POLLER_LIB_ONLY=1
export HOST_NAME='lab_host*[1]'
export SMART_POLICY=paranoid
export DRIVES_FILE="${tmpdir}/drives.conf"
export USERS_FILE="${tmpdir}/users.conf"
export STATE_FILE="${tmpdir}/state.json"
export STATE_LOCK="${tmpdir}/state.lock"
export TMPDIR="${tmpdir}/tmp"
mkdir -p "$TMPDIR" "${tmpdir}/api"
make_fake_smartctl "$tmpdir"
export SMARTCTL_BIN="${tmpdir}/smartctl"
READS="${tmpdir}/reads.log"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/bot_poller.sh"
record_tg_api "${tmpdir}/api"
state_init

AUTH=1001
PUNCT_DRIVE='/dev/disk/by-id/ata-Fixture_HDD_[A]*1'
echo "$AUTH" > "$USERS_FILE"
printf '%s\n' "$PUNCT_DRIVE" /dev/nvme0n1 /dev/sdc > "$DRIVES_FILE"
map_drive "$tmpdir" "$PUNCT_DRIVE" "${REPORT_FIXTURES}/ata_healthy.json"
map_drive "$tmpdir" /dev/nvme0n1 "${REPORT_FIXTURES}/nvme_worn.json"
# The first read of /dev/sdc is critical, any later read healthy. Reading the
# drive twice would make the verdict and the attached output disagree.
map_drive "$tmpdir" /dev/sdc "${REPORT_FIXTURES}/ata_critical.json,${REPORT_FIXTURES}/ata_healthy.json"

reset_calls() {
    : > "${TG_RECORD_DIR}/calls.jsonl"
    : > "$READS"
}

# --- /scan: one acknowledgement, one compact report, no attachment ---------------
reset_calls
handle_command "$AUTH" "/scan"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage" "/scan API calls"
assert_eq "$(tg_calls '[.[].fields | has("parse_mode")] | any')" "false" "/scan uses plain text"
assert_eq "$(tg_calls '[.[].fields.chat_id] | unique | join(",")')" "$AUTH" "/scan chat"
ack="$(tg_calls -r '.[0].fields.text')"
report="$(tg_calls -r '.[1].fields.text')"
assert_eq "$ack" "🔍 Scanning 3 drives on lab_host*[1]…" "/scan acknowledgement"
assert_contains "$report" "🔴 SMART scan · lab_host*[1]" "/scan title"
assert_contains "$report" "🟢 1 good · 🟠 1 degraded · 🔴 1 critical" "/scan counts"
assert_contains "$report" "🟢 ${PUNCT_DRIVE} — GOOD" "/scan literal drive path"
assert_contains "$report" "🔴 /dev/sdc — CRITICAL" "/scan verdict from the first read"
assert_contains "$report" "Wear  ▰▰▰▰▰▰▰▰▰▰ 117% used · past rated endurance" "/scan wear gauge"
assert_contains "$report" "Send /full for raw smartctl output." "/scan footer"
for drive in "$PUNCT_DRIVE" /dev/nvme0n1 /dev/sdc; do
    assert_eq "$(reads_of "$READS" "$drive")" "1" "/scan smartctl reads of ${drive}"
    assert_eq "$(reads_of "$READS" "$drive" "--json=o")" "1" "/scan reads ${drive} with --json=o"
done
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "/scan left temp files: $(ls -A "$TMPDIR")"

# --- /full: same cards plus one Markdown attachment from the same reads -------------
reset_calls
handle_command "$AUTH" "/full@fixture_bot"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage,sendDocument" "/full API calls"
assert_eq "$(tg_calls '[.[].fields | has("parse_mode")] | any')" "false" "/full uses plain text"
assert_eq "$(tg_calls -r '.[0].fields.text')" "🔍 Full scan of 3 drives on lab_host*[1]… the raw output follows as a file." "/full acknowledgement"
cards="$(tg_calls -r '.[1].fields.text')"
assert_contains "$cards" "🔴 SMART full report · lab_host*[1]" "/full title"
assert_contains "$cards" "🔴 /dev/sdc — CRITICAL" "/full card verdict"
assert_contains "$cards" "   • Current_Pending_Sector(197)=2" "/full card evidence"
for drive in "$PUNCT_DRIVE" /dev/nvme0n1 /dev/sdc; do
    assert_eq "$(reads_of "$READS" "$drive")" "1" "/full smartctl reads of ${drive}"
done

doc="$(tg_calls -r '.[2].fields.document_copy')"
doc_path="$(tg_calls -r '.[2].fields.document_path')"
doc_name="$(tg_calls -r '.[2].fields.document_name')"
caption="$(tg_calls -r '.[2].fields.caption')"
assert_eq "$(tg_calls -r '.[2].fields.chat_id')" "$AUTH" "/full attachment chat"
[[ "$doc_name" =~ ^smart-full-lab_host__1_-[0-9]{8}-[0-9]{6}\.md$ ]] || fail "unexpected attachment name: ${doc_name}"
assert_eq "$caption" "📄 Full SMART report · lab_host*[1] · worst: CRITICAL" "/full caption"
[[ ! -e "$doc_path" ]] || fail "attachment temp file was not deleted: ${doc_path}"
[[ "$doc_path" == "${TMPDIR}/smart-full."* ]] || fail "attachment not in a unique temp dir: ${doc_path}"
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "/full left temp files: $(ls -A "$TMPDIR")"

attachment="$(cat "$doc")"
assert_contains "$attachment" "# SMART full report" "attachment heading"
assert_contains "$attachment" "$cards" "attachment repeats the cards"
assert_contains "$attachment" '## 🔴 `/dev/sdc` — CRITICAL' "attachment drive section"
assert_contains "$attachment" '- `Current_Pending_Sector(197)=2`' "attachment evidence"
assert_contains "$attachment" '- `nvme_percentage_used=117>=80`' "attachment NVMe evidence"
assert_contains "$attachment" "Device Model:     Fixture HDD 2000" "attachment raw text of the critical read"
assert_contains "$attachment" "197 Current_Pending_Sector  0x0032   100   100   000    Old_age   Always       -       2" "attachment raw attribute row"
assert_contains "$attachment" "Model Number:                       Fixture NVMe 2TB" "attachment raw NVMe text"
sdc_section="$(awk '/^## .*`\/dev\/sdc`/ { on = 1 } on' <<< "$attachment")"
assert_not_contains "$sdc_section" "Fixture HDD 4000" "attachment mixes in a second read"

# A second /full gets its own temp dir, also deleted.
reset_calls
handle_command "$AUTH" "/full"
second_path="$(tg_calls -r '.[2].fields.document_path')"
[[ "$second_path" != "$doc_path" ]] || fail "temp attachment path reused: ${second_path}"
[[ ! -e "$second_path" ]] || fail "second attachment temp file was not deleted"

# A failed upload is reported, since the report already says a file follows.
reset_calls
TG_FAIL_METHOD=sendDocument handle_command "$AUTH" "/full"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage,sendDocument,sendMessage" "/full with a failed upload"
assert_eq "$(tg_calls -r '.[3].fields.text')" "⚠️ The raw output file could not be uploaded. Check the container logs." "/full upload failure notice"
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "failed /full left temp files: $(ls -A "$TMPDIR")"

# A drive missing from the records gives a warning, never a report that looks complete.
reset_calls
eval "real_$(declare -f report_collect)"
report_collect() { real_report_collect "$@"; : > "$1/records.jsonl"; }
handle_command "$AUTH" "/full"
eval "$(declare -f real_report_collect | sed '1s/^real_//')"
assert_eq "$(tg_calls 'map(.method) | join(",")')" "sendMessage,sendMessage" "/full with missing records"
assert_eq "$(tg_calls -r '.[1].fields.text')" "⚠️ SMART full on lab_host*[1] failed: the report could not be built. Check the container logs." "missing records warning"
[[ -z "$(ls -A "$TMPDIR")" ]] || fail "failed report left temp files: $(ls -A "$TMPDIR")"

# --- Advisory-only drives are not labelled critical -----------------------------------
reset_calls
printf '%s\n' /dev/sdb > "$DRIVES_FILE"
map_drive "$tmpdir" /dev/sdb "${REPORT_FIXTURES}/ata_advisory.json"
handle_command "$AUTH" "/scan"
advisory="$(tg_calls -r '.[1].fields.text')"
assert_contains "$advisory" "Worst: ADVISORY · 1 drive" "advisory overview"
assert_not_contains "$advisory" "CRITICAL" "advisory report mislabeled"

# --- One command list: /help, setMyCommands and dispatch ------------------------------
reset_calls
if TG_FAIL_METHOD=setMyCommands register_commands; then
    fail "register_commands hid a failed setMyCommands (main retries on failure)"
fi
reset_calls
register_commands
assert_eq "$(tg_calls -r '.[0].method')" "setMyCommands" "setMyCommands call"
menu="$(tg_calls -c '.[0].fields.commands | fromjson')"
assert_eq "$menu" "$(bot_commands_json)" "setMyCommands payload"
assert_eq "$(jq -r 'map(.command) | join(",")' <<< "$menu")" "scan,full,heartbeat,help" "menu commands"
jq -e 'all(.[]; (.command | test("^[a-z0-9_]{1,32}$")) and (.description | length) >= 1 and (.description | length) <= 256)' <<< "$menu" >/dev/null \
    || fail "command menu breaks Telegram's limits: ${menu}"

reset_calls
handle_command "$AUTH" "/help"
help="$(tg_calls -r '.[0].fields.text')"
assert_eq "$(tg_calls '.[0].fields | has("parse_mode")')" "false" "/help uses plain text"
assert_eq "$(grep -E '^/[a-z]+ — ' <<< "$help")" "$(jq -r '.[] | "/\(.command) — \(.description)"' <<< "$menu")" "/help matches the menu"

while IFS= read -r command; do
    reset_calls
    handle_command "$AUTH" "/${command}"
    [[ "$(tg_calls 'length')" -gt 0 ]] || fail "/${command} sent nothing"
    assert_not_contains "$(tg_calls -r '[.[].fields.text // ""] | join("\n")')" "Unknown command" "/${command} dispatch"
done < <(jq -r '.[].command' <<< "$menu")

# --- Unauthorized chats get no report ---------------------------------------------------
reset_calls
handle_command 999 "/scan"
assert_eq "$(tg_calls 'length')" "1" "unauthorized reply count"
assert_eq "$(tg_calls -r '.[0].fields.text')" "⛔ unauthorized chat id: 999" "unauthorized reply"
assert_eq "$(wc -l < "$READS" | tr -d ' ')" "0" "unauthorized /scan read drives"

echo "scan_report_test: ok"
