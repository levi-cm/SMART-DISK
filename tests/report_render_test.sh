#!/usr/bin/env bash
# Report renderer: verdict cards, gauges, zero vs missing values, wear above
# 100%, literal punctuation, empty and malformed input, long-report splitting.
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
make_fake_smartctl "$tmpdir"
export SMARTCTL_BIN="${tmpdir}/smartctl"

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/bot_poller.sh"

GENERATED="2026-01-01 00:00 UTC"
PUNCT_DRIVE='/dev/disk/by-id/ata-Fixture_HDD_[A]*1'
map_drive "$tmpdir" "$PUNCT_DRIVE" "${REPORT_FIXTURES}/ata_healthy.json"
map_drive "$tmpdir" /dev/sdb "${REPORT_FIXTURES}/ata_advisory.json"
map_drive "$tmpdir" /dev/nvme0n1 "${REPORT_FIXTURES}/nvme_worn.json"
map_drive "$tmpdir" /dev/sdc "${REPORT_FIXTURES}/ata_critical.json"
map_drive "$tmpdir" /dev/nvme1n1 "${REPORT_FIXTURES}/nvme_zero.json"
map_drive "$tmpdir" /dev/nvme2n1 "${REPORT_FIXTURES}/nvme_missing.json"
map_drive "$tmpdir" /dev/sdm "${ROOT_DIR}/tests/fixtures/smartctl/malformed.json"
map_drive "$tmpdir" /dev/sdh "${REPORT_FIXTURES}/ata_healthy.json"

# collect <drive...>: prints the records file for those drives.
collect() {
    local w
    w="$(mktemp -d "${tmpdir}/collect.XXXXXX")"
    report_collect "$w" "$@"
    echo "${w}/records.jsonl"
}

# card_of <report> <drive>: the card block for one drive.
card_of() {
    awk -v d=" $2 — " 'index($0, d) { on = 1 } on && $0 == "" { exit } on { print }' <<< "$1"
}

# --- Mixed severity: golden output -------------------------------------------
records="$(collect "$PUNCT_DRIVE" /dev/sdb /dev/nvme0n1 /dev/sdc)"
scan="$(report_render scan "$records" "$GENERATED")"
golden="${REPORT_FIXTURES}/expected_scan_mixed.txt"
if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    printf '%s\n' "$scan" > "$golden"
fi
if [[ "$scan" != "$(cat "$golden")" ]]; then
    diff -u "$golden" <(printf '%s\n' "$scan") >&2 || true
    fail "mixed-severity /scan report differs from ${golden#"${ROOT_DIR}/"}"
fi
assert_contains "$scan" "Worst: CRITICAL · 4 drives" "overview worst severity"
assert_contains "$scan" "🟢 1 good · 🟡 1 advisory · 🟠 1 degraded · 🔴 1 critical" "overview counts"
w="$(mktemp -d "${tmpdir}/worst.XXXXXX")"
report_collect "$w" "$PUNCT_DRIVE" /dev/sdb /dev/nvme0n1
assert_eq "$REPORT_WORST" "degraded" "worst severity without the critical drive"
report_collect "$w" /dev/sdb /dev/sdc /dev/sdh
assert_eq "$REPORT_WORST" "critical" "worst severity with a critical drive"

# Plain text: punctuation in paths and labels is shown as is.
assert_contains "$scan" "🟢 ${PUNCT_DRIVE} — GOOD" "literal drive path"
assert_contains "$scan" "SMART scan · lab_host*[1]" "literal host label"

# Evidence: most severe first; /scan keeps three lines, /full shows all.
critical_card="$(card_of "$scan" /dev/sdc)"
assert_eq "$(sed -n 4p <<< "$critical_card")" "   • Offline_Uncorrectable(198)=1" "critical evidence leads"
assert_contains "$critical_card" "   • +2 more, see /full" "/scan evidence truncation"
full="$(report_render full "$records" "$GENERATED")"
full_card="$(card_of "$full" /dev/sdc)"
for item in "Offline_Uncorrectable(198)=1" "Current_Pending_Sector(197)=2" "Reported_Uncorrect(187)=4" "Reallocated_Sector_Ct(5)=8" "UDMA_CRC_Error_Count(199)=3"; do
    assert_contains "$full_card" "   • ${item}" "/full evidence"
done
assert_not_contains "$full_card" "more, see /full" "/full evidence truncation"
assert_contains "$full" "SMART full report · lab_host*[1]" "/full title"
assert_contains "$full" "📎 Raw smartctl output and evidence: attached file." "/full footer"

# --- All healthy ---------------------------------------------------------------
healthy="$(report_render scan "$(collect "$PUNCT_DRIVE" /dev/sdh)" "$GENERATED")"
assert_eq "$(head -n 1 <<< "$healthy")" "🟢 SMART scan · lab_host*[1]" "healthy title"
assert_contains "$healthy" "Worst: GOOD · 2 drives" "healthy overview"
assert_eq "$(sed -n 3p <<< "$healthy")" "🟢 2 good" "healthy counts"

# --- Zero versus missing values --------------------------------------------------
zm="$(report_render scan "$(collect /dev/nvme1n1 /dev/nvme2n1)" "$GENERATED")"
zero_card="$(card_of "$zm" /dev/nvme1n1)"
assert_contains "$zero_card" "   🌡 0 °C · ⏱ 0 h" "zero temperature and hours"
assert_contains "$zero_card" "   Wear  ▱▱▱▱▱▱▱▱▱▱ 0% used" "zero wear gauge"
assert_contains "$zero_card" "   Spare ▱▱▱▱▱▱▱▱▱▱ 0% (min 0%)" "zero spare gauge"
missing_card="$(card_of "$zm" /dev/nvme2n1)"
assert_contains "$missing_card" "   🌡 — · ⏱ —" "missing temperature and hours"
assert_contains "$missing_card" "   Wear  —" "missing wear"
assert_contains "$missing_card" "   Spare —" "missing spare"
assert_not_contains "$missing_card" "0 °C" "missing temperature shown as 0"
assert_not_contains "$missing_card" "0%" "missing gauge shown as 0"
assert_not_contains "$missing_card" "▱" "missing gauge drawn as empty bar"

# --- Wear above 100% -------------------------------------------------------------
worn_card="$(card_of "$scan" /dev/nvme0n1)"
assert_contains "$worn_card" "   Wear  ▰▰▰▰▰▰▰▰▰▰ 117% used · past rated endurance" "wear above 100%"
assert_contains "$worn_card" "   Spare ▰▰▰▰▰▰▰▰▰▰ 100% (min 10%)" "full spare gauge"

# Gauge cells for edge values (synthetic records, renderer only).
gauge_records="${tmpdir}/gauges.jsonl"
for pct in 0 1 5 49 50 96 100 117 255; do
    jq -n -c --argjson p "$pct" '{drive: "/dev/g\($p)", severity: "ok", reasons: [],
        metrics: {is_nvme: true, nvme_used_pct: $p, nvme_spare_pct: $p, nvme_spare_thresh_pct: null}}'
done > "$gauge_records"
gauges="$(report_render scan "$gauge_records" "$GENERATED")"
while IFS='|' read -r pct bar suffix; do
    assert_contains "$(card_of "$gauges" "/dev/g${pct}")" "   Wear  ${bar} ${pct}% used${suffix}" "wear gauge ${pct}%"
    assert_contains "$(card_of "$gauges" "/dev/g${pct}")" "   Spare ${bar} ${pct}%" "spare gauge ${pct}%"
done <<'CASES'
0|▱▱▱▱▱▱▱▱▱▱|
1|▰▱▱▱▱▱▱▱▱▱|
5|▰▱▱▱▱▱▱▱▱▱|
49|▰▰▰▰▰▱▱▱▱▱|
50|▰▰▰▰▰▱▱▱▱▱|
96|▰▰▰▰▰▰▰▰▰▱|
100|▰▰▰▰▰▰▰▰▰▰|
117|▰▰▰▰▰▰▰▰▰▰| · past rated endurance
255|▰▰▰▰▰▰▰▰▰▰| · past rated endurance
CASES

# --- Unwritable temp dir: the drive stays in the report with its verdict -------------------
ro="$(mktemp -d "${tmpdir}/ro.XXXXXX")"
: > "${ro}/records.jsonl"
chmod 555 "$ro"
report_collect "$ro" /dev/sdc 2>/dev/null
chmod 755 "$ro"
assert_eq "$(jq -r '[.drive, .severity, (.reasons | join(","))] | join(" ")' "${ro}/records.jsonl")" \
    "/dev/sdc critical smartctl_no_output" "record without a snapshot file"

# --- Malformed snapshot and empty input ----------------------------------------------
malformed="$(report_render scan "$(collect /dev/sdm)" "$GENERATED")"
assert_contains "$malformed" "🔴 /dev/sdm — CRITICAL" "malformed snapshot verdict"
assert_contains "$malformed" "   • jq_parse_failed" "malformed snapshot evidence"
assert_contains "$malformed" "   🌡 — · ⏱ —" "malformed snapshot metrics"

: > "${tmpdir}/empty.jsonl"
empty="$(report_render scan "${tmpdir}/empty.jsonl" "$GENERATED")"
assert_contains "$empty" "No drives configured: nothing was checked." "empty report"
for word in GOOD healthy "🟢" "Worst:"; do
    assert_not_contains "$empty" "$word" "empty report claims health"
done
report_collect "$w"
assert_eq "$REPORT_WORST" "none" "worst severity with no drives"

# --- Hung drives: the read is cut off and the drive reported critical -----------------
# /dev/sdy ignores TERM, as a drive stuck in error recovery can, so timeout
# needs KILL (exit 137 instead of 124).
cat > "${tmpdir}/hung-smartctl" <<'SH'
#!/usr/bin/env bash
[[ "$3" == /dev/sdy ]] && trap '' TERM
exec sleep 30
SH
chmod +x "${tmpdir}/hung-smartctl"
# Shorten the KILL grace to 0.2 s for these reads; exit codes are unchanged.
# shellcheck disable=SC2317,SC2329 # called by report_collect
timeout() { [[ "$1" == -k ]] && set -- -k 0.2 "${@:3}"; command timeout "$@"; }
hung_records="$(SMARTCTL_BIN="${tmpdir}/hung-smartctl" SMARTCTL_TIMEOUT=1 collect /dev/sdx /dev/sdy 2>/dev/null)"
unset -f timeout
hung="$(report_render scan "$hung_records" "$GENERATED")"
for drive in /dev/sdx /dev/sdy; do
    card="$(card_of "$hung" "$drive")"
    assert_contains "$card" "🔴 ${drive} — CRITICAL" "hung drive verdict (${drive})"
    assert_contains "$card" "   • smartctl_timeout=1s" "hung drive evidence (${drive})"
    assert_contains "$card" "   🌡 — · ⏱ —" "hung drive metrics (${drive})"
done

# --- Long report: split under Telegram's limit at card boundaries ---------------------
long_records="${tmpdir}/long.jsonl"
for i in $(seq 1 80); do
    jq -c --arg d "/dev/disk/by-id/nvme-Fixture_Long_Name_${i}" '.drive = $d' <<< "$(sed -n 3p "$records")"
done > "$long_records"
long="$(report_render full "$long_records" "$GENERATED")"
(( $(utf16_units "$long") > 4096 )) || fail "long report fixture is not long enough"
chunks=()
while IFS= read -r -d '' chunk; do
    chunks+=("$chunk")
done < <(tg_split_text "$long")
(( ${#chunks[@]} > 1 )) || fail "long report was not split"
cards=0
for chunk in "${chunks[@]}"; do
    units="$(utf16_units "$chunk")"
    (( units > 0 && units <= 4096 )) || fail "chunk of ${units} units breaks Telegram's limit"
    (( units <= TG_CHUNK_LIMIT )) || fail "chunk of ${units} units exceeds TG_CHUNK_LIMIT"
    first="$(head -n 1 <<< "$chunk")"
    [[ "$first" == "🟠 SMART full report"* || "$first" == "🟠 /dev/disk/by-id/nvme-Fixture_Long_Name_"* || "$first" == "📎 "* ]] \
        || fail "chunk starts mid-card: ${first}"
    cards=$((cards + $(grep -c '^🟠 /dev/' <<< "$chunk")))
done
assert_eq "$cards" "80" "cards across chunks"
joined="$(printf '%s\n\n' "${chunks[@]}")"
assert_eq "${joined%$'\n\n'}" "$long" "split chunks rejoin to the original"

echo "report_render_test: ok"
