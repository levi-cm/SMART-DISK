#!/usr/bin/env bash
# Shared SMART result parsing and alert-state decisions.
# shellcheck disable=SC2034 # Parsed fields are intentional globals consumed by callers.

smart_parse_result() {
    local result="$1" payload severity_field

    SMART_RESULT_STATUS="${result%% *}"
    result="${result#* }"
    SMART_RESULT_DRIVE="${result%% *}"
    if [[ "$result" == *" "* ]]; then
        payload="${result#* }"
    else
        payload=""
    fi

    SMART_RESULT_SEVERITY="ok"
    SMART_RESULT_REASON="-"
    if [[ "$payload" == severity=* ]]; then
        severity_field="${payload%%|*}"
        SMART_RESULT_SEVERITY="${severity_field#severity=}"
        if [[ "$payload" == *"|"* ]]; then
            SMART_RESULT_REASON="${payload#*|}"
        fi
    elif [[ "$SMART_RESULT_STATUS" != "OK" ]]; then
        # Compatibility with state/results created before severity support.
        SMART_RESULT_SEVERITY="critical"
        SMART_RESULT_REASON="${payload:--}"
    fi
}

smart_severity_rank() {
    case "$1" in
        advisory) echo 1 ;;
        degraded) echo 2 ;;
        critical) echo 3 ;;
        *) echo 0 ;;
    esac
}

smart_severity_label() {
    case "$1" in
        advisory) echo "ADVISORY" ;;
        degraded) echo "DEGRADED" ;;
        critical) echo "CRITICAL" ;;
        *) echo "GOOD" ;;
    esac
}

smart_severity_icon() {
    case "$1" in
        advisory) echo "🟡" ;;
        degraded) echo "🟠" ;;
        critical) echo "🔴" ;;
        *) echo "🟢" ;;
    esac
}

smart_alert_action() {
    local policy="$1" status="$2" severity="$3" reason="$4"
    local last_status="$5" last_severity="$6" last_reason="$7"
    local last_alert="$8" now="$9" reminder_interval="${10}"

    if [[ "$status" == "OK" ]]; then
        if [[ -n "$last_status" && "$last_status" != "OK" ]]; then
            echo "recovery"
        else
            echo "none"
        fi
        return
    fi

    if [[ -z "$last_status" || "$last_status" == "OK" || "$last_severity" != "$severity" || "$last_reason" != "$reason" ]]; then
        if [[ "$policy" == "paranoid" || "$severity" == "critical" ]]; then
            echo "burst"
        else
            echo "alert"
        fi
        return
    fi

    if (( now - last_alert >= reminder_interval )); then
        echo "reminder"
    else
        echo "none"
    fi
}
