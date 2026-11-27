#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_case() {
    local fixture="$1"
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/smartctl" <<'SH'
#!/usr/bin/env bash
cat "$SMARTCTL_FIXTURE"
SH
    chmod +x "${tmp}/smartctl"

    SMARTCTL_BIN="${tmp}/smartctl" SMARTCTL_FIXTURE="$fixture" \
        bash "${ROOT_DIR}/scripts/smart_check.sh" /dev/test

    rm -rf "$tmp"
}

fixture() {
    local file="$1"
    shift
    cat > "$file"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

FIXTURES="${ROOT_DIR}/tests/fixtures/smartctl"

assert_case() {
    local policy="$1" fixture_name="$2" expected="$3"
    local out
    out="$(SMART_POLICY="$policy" run_case "${FIXTURES}/${fixture_name}")"
    [[ "$out" == "$expected" ]] || fail "${policy}/${fixture_name}: expected '${expected}', got: '${out}'"
}

assert_case paranoid ata_healthy.json "OK /dev/test"
assert_case paranoid nvme_healthy.json "OK /dev/test"
assert_case paranoid ata_historical_counters.json "FAIL /dev/test severity=advisory|UDMA_CRC_Error_Count(199)=3|smart_error_log_count=2"
assert_case balanced ata_historical_counters.json "WARN /dev/test severity=advisory|UDMA_CRC_Error_Count(199)=3|smart_error_log_count=2"
assert_case paranoid nvme_historical_counters.json "FAIL /dev/test severity=advisory|nvme_error_log_entries=7"
assert_case balanced nvme_historical_counters.json "WARN /dev/test severity=advisory|nvme_error_log_entries=7"
assert_case paranoid ata_pending_sectors.json "FAIL /dev/test severity=critical|Current_Pending_Sector(197)=2"
assert_case balanced ata_pending_sectors.json "FAIL /dev/test severity=critical|Current_Pending_Sector(197)=2"
assert_case balanced ata_self_test_failure.json "FAIL /dev/test severity=critical|self_test_failures=1"
# Failed self-test flagged only by status.passed=false, with no failure text.
assert_case paranoid ata_self_test_failed_flag_only.json "FAIL /dev/test severity=critical|self_test_failures=1"
assert_case balanced ata_self_test_failed_flag_only.json "FAIL /dev/test severity=critical|self_test_failures=1"
assert_case balanced ata_temperature.json "FAIL /dev/test severity=degraded|temp=51C>50C"
assert_case balanced nvme_wear.json "FAIL /dev/test severity=degraded|nvme_percentage_used=85>=80"
assert_case balanced malformed.json "FAIL /dev/test severity=critical|jq_parse_failed"

fixture "${tmpdir}/exit-warning.json" <<'JSON'
{
  "smartctl": {"exit_status": 4},
  "smart_status": {"passed": true},
  "temperature": {"current": 30},
  "ata_smart_attributes": {"table": []}
}
JSON
out="$(run_case "${tmpdir}/exit-warning.json")"
[[ "$out" == "FAIL /dev/test severity=advisory|smartctl_exit_status=4" ]] || fail "expected smartctl exit warning, got: $out"

fixture "${tmpdir}/crc-error.json" <<'JSON'
{
  "smartctl": {"exit_status": 0},
  "smart_status": {"passed": true},
  "temperature": {"current": 30},
  "ata_smart_attributes": {
    "table": [
      {"id": 199, "name": "UDMA_CRC_Error_Count", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 1}}
    ]
  }
}
JSON
out="$(run_case "${tmpdir}/crc-error.json")"
[[ "$out" == "FAIL /dev/test severity=advisory|UDMA_CRC_Error_Count(199)=1" ]] || fail "expected CRC error, got: $out"

fixture "${tmpdir}/warm.json" <<'JSON'
{
  "smartctl": {"exit_status": 0},
  "smart_status": {"passed": true},
  "temperature": {"current": 51},
  "ata_smart_attributes": {"table": []}
}
JSON
out="$(run_case "${tmpdir}/warm.json")"
[[ "$out" == "FAIL /dev/test severity=degraded|temp=51C>50C" ]] || fail "expected paranoid temp warning, got: $out"

fixture "${tmpdir}/normal-counters.json" <<'JSON'
{
  "smartctl": {"exit_status": 0},
  "smart_status": {"passed": true},
  "temperature": {"current": 30},
  "ata_smart_attributes": {
    "table": [
      {"id": 9, "name": "Power_On_Hours", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 999}},
      {"id": 12, "name": "Power_Cycle_Count", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 123}},
      {"id": 241, "name": "Total_LBAs_Written", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 999999}}
    ]
  }
}
JSON
out="$(run_case "${tmpdir}/normal-counters.json")"
[[ "$out" == "OK /dev/test" ]] || fail "expected normal counters ignored, got: $out"

fixture "${tmpdir}/unknown-vendor-attr.json" <<'JSON'
{
  "smartctl": {"exit_status": 0},
  "smart_status": {"passed": true},
  "temperature": {"current": 30},
  "ata_smart_attributes": {
    "table": [
      {"id": 11, "name": "Unknown_SSD_Attribute", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 401}}
    ]
  }
}
JSON
out="$(run_case "${tmpdir}/unknown-vendor-attr.json")"
[[ "$out" == "OK /dev/test" ]] || fail "expected unknown vendor attr ignored, got: $out"

# Snapshot mode: evaluates a saved snapshot and never reads the drive again.
cat > "${tmpdir}/smartctl-must-not-run" <<'SH'
#!/usr/bin/env bash
echo "smartctl called" >> "${SMARTCTL_CALLS:?}"
SH
chmod +x "${tmpdir}/smartctl-must-not-run"
out="$(SMARTCTL_BIN="${tmpdir}/smartctl-must-not-run" SMARTCTL_CALLS="${tmpdir}/calls" \
    bash "${ROOT_DIR}/scripts/smart_check.sh" /dev/test "${FIXTURES}/ata_pending_sectors.json")"
[[ "$out" == "FAIL /dev/test severity=critical|Current_Pending_Sector(197)=2" ]] || fail "snapshot verdict, got: $out"
[[ ! -e "${tmpdir}/calls" ]] || fail "smart_check.sh read the drive despite a snapshot"
out="$(bash "${ROOT_DIR}/scripts/smart_check.sh" /dev/test "${tmpdir}/missing-snapshot.json")"
[[ "$out" == "FAIL /dev/test severity=critical|smartctl_no_output" ]] || fail "missing snapshot, got: $out"

echo "smart_check_test: ok"
