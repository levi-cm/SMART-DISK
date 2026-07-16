#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
export BOT_POLLER_LIB_ONLY=1

# shellcheck disable=SC1091 # ROOT_DIR is resolved at runtime.
source "${ROOT_DIR}/scripts/bot_poller.sh"

cat > "${tmpdir}/smart_check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$SMART_RESULT_FIXTURE"
SH
cat > "${tmpdir}/smartctl" <<'SH'
#!/usr/bin/env bash
echo "fixture SMART output"
SH
chmod +x "${tmpdir}/smart_check" "${tmpdir}/smartctl"
echo "/dev/test" > "${tmpdir}/drives.conf"

export SMART_CHECK_BIN="${tmpdir}/smart_check"
export SMARTCTL_BIN="${tmpdir}/smartctl"
export DRIVES_FILE="${tmpdir}/drives.conf"
export SMART_RESULT_FIXTURE="WARN /dev/test severity=advisory|smart_error_log_count=2"

overall="$(build_scan_report "${tmpdir}/report.md")"
[[ "$overall" == "advisory" ]] || fail "expected advisory overall result, got ${overall}"
grep -q 'ADVISORY' "${tmpdir}/report.md" || fail "advisory label missing from report"
if grep -q 'CRITICAL' "${tmpdir}/report.md"; then
    fail "advisory report mislabeled critical"
fi

echo "scan_report_test: ok"
