#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
export ENTRYPOINT_LIB_ONLY=1
export BURST_COUNT=1
export BURST_DELAY=0

# shellcheck disable=SC1091 # ROOT_DIR is resolved at runtime.
source "${ROOT_DIR}/scripts/entrypoint.sh"

tg_send() {
    printf '%s\n' "$1"
}

advisory="$(severity_alert /dev/test advisory 'smart_error_log_count=2')"
[[ "$advisory" == *"SMART ADVISORY"* ]] || fail "advisory heading missing"
[[ "$advisory" == *"Historical or cumulative counters are evidence to investigate, not proof of imminent failure."* ]] || fail "advisory accuracy guidance missing"
[[ "$advisory" != *"DRIVE FAILURE"* ]] || fail "advisory mislabeled as drive failure"
[[ "$advisory" != *"Replace it"* ]] || fail "advisory claims replacement certainty"

degraded="$(severity_alert /dev/test degraded 'temp=51C>50C')"
[[ "$degraded" == *"SMART DEGRADED"* ]] || fail "degraded heading missing"
[[ "$degraded" == *"Investigate promptly"* ]] || fail "degraded guidance missing"

critical="$(burst_alert /dev/test critical 'Current_Pending_Sector(197)=2')"
[[ "$critical" == *"SMART CRITICAL"* ]] || fail "critical heading missing"
[[ "$critical" == *"ACT NOW"* ]] || fail "critical action guidance missing"

echo "message_accuracy_test: ok"
