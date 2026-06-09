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

fixture "${tmpdir}/exit-warning.json" <<'JSON'
{
  "smartctl": {"exit_status": 4},
  "smart_status": {"passed": true},
  "temperature": {"current": 30},
  "ata_smart_attributes": {"table": []}
}
JSON
out="$(run_case "${tmpdir}/exit-warning.json")"
[[ "$out" == "FAIL /dev/test smartctl_exit_status=4" ]] || fail "expected smartctl exit warning, got: $out"

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
[[ "$out" == "FAIL /dev/test UDMA_CRC_Error_Count(199)=1" ]] || fail "expected CRC error, got: $out"

fixture "${tmpdir}/warm.json" <<'JSON'
{
  "smartctl": {"exit_status": 0},
  "smart_status": {"passed": true},
  "temperature": {"current": 51},
  "ata_smart_attributes": {"table": []}
}
JSON
out="$(run_case "${tmpdir}/warm.json")"
[[ "$out" == "FAIL /dev/test temp=51C>50C" ]] || fail "expected paranoid temp warning, got: $out"

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

echo "smart_check_test: ok"
