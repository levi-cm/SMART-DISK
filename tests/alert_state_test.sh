#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${ROOT_DIR}/tests/fixtures/alert_state/transitions.json"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "${ROOT_DIR}/scripts/smart_result_lib.sh" ]] || fail "missing scripts/smart_result_lib.sh"
# shellcheck disable=SC1091 # ROOT_DIR is resolved at runtime.
source "${ROOT_DIR}/scripts/smart_result_lib.sh"

while IFS=$'\037' read -r name policy status severity reason last_status last_severity last_reason last_alert now reminder expected; do
    actual="$(smart_alert_action "$policy" "$status" "$severity" "$reason" "$last_status" "$last_severity" "$last_reason" "$last_alert" "$now" "$reminder")"
    [[ "$actual" == "$expected" ]] || fail "${name}: expected ${expected}, got ${actual}"
done < <(jq -r '.[] | [.name,.policy,.status,.severity,.reason,.last_status,.last_severity,.last_reason,(.last_alert|tostring),(.now|tostring),(.reminder|tostring),.expected] | join("\u001f")' "$FIXTURE")

echo "alert_state_test: ok"
