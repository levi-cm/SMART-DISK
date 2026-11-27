#!/usr/bin/env bash
# entrypoint.sh — main loop.
# Polls each drive in /config/drives.conf every $SCAN_INTERVAL seconds.
# Maintains /state/last_status.json to drive state-machine alerts.
# shellcheck disable=SC2016

set -uo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/telegram.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/state_lib.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/smart_result_lib.sh"

DRIVES_FILE="${DRIVES_FILE:-/config/drives.conf}"
SMART_CHECK_BIN="${SMART_CHECK_BIN:-${SCRIPTS_DIR}/smart_check.sh}"
SMART_POLICY="${SMART_POLICY:-paranoid}"
SCAN_INTERVAL="${SCAN_INTERVAL:-21600}"
BURST_COUNT="${BURST_COUNT:-10}"
BURST_DELAY="${BURST_DELAY:-30}"
REMINDER_INTERVAL="${REMINDER_INTERVAL:-86400}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-4}"
HOST_NAME="${HOST_NAME:-$(hostname)}"

log() {
    echo "[$(date -Iseconds)] $*"
}

# state_get <drive> <field>
state_get() {
    state_read '.[$d][$f] // empty' --arg d "$1" --arg f "$2"
}

# state_set <drive> <status> <severity> <reason> <last_alert_epoch>
state_set() {
    state_apply '.[$d] = {status: $s, severity: $v, reason: $r, last_alert: $t}' \
        --arg d "$1" --arg s "$2" --arg v "$3" --arg r "$4" --argjson t "$5"
}

# meta_get <field>
meta_get() {
    state_read '._meta[$f] // empty' --arg f "$1"
}

# meta_set <field> <numeric_value>
meta_set() {
    state_apply '._meta = (._meta // {}) | ._meta[$f] = $v' \
        --arg f "$1" --argjson v "$2"
}

heartbeat_alert() {
    local n_drives="$1" scan_count="$2"
    shift 2
    local drive_lines="" drive
    for drive in "$@"; do
        drive_lines+="• \`${drive}\` ✅"$'\n'
    done

    local text
    text=$(cat <<EOF
😎 *EVERYTHING AWESOME* 😎
HOST: \`${HOST_NAME}\`
TIME: \`$(date -Iseconds)\`
SCAN #${scan_count} — heartbeat every ${HEARTBEAT_EVERY} scans

${drive_lines}
All ${n_drives} drives healthy. Next heartbeat in $((HEARTBEAT_EVERY * SCAN_INTERVAL / 3600))h.
EOF
)
    tg_send "$text"
}

severity_heading() {
    case "$1" in
        advisory) echo "🟡 *SMART ADVISORY*" ;;
        degraded) echo "🟠 *SMART DEGRADED*" ;;
        critical) echo "🔴 *SMART CRITICAL*" ;;
        *) echo "⚠️ *SMART WARNING*" ;;
    esac
}

severity_guidance() {
    case "$1" in
        advisory)
            echo "Historical or cumulative counters are evidence to investigate, not proof of imminent failure. Check trends, logs, cabling, and backups."
            ;;
        degraded)
            echo "Active health margin is degraded. Investigate promptly, verify backups, and correct temperature or wear conditions."
            ;;
        critical)
            echo "⚠️ ACT NOW. CHECK BACKUPS. Active failure indicators need immediate diagnosis and may require drive replacement. ⚠️"
            ;;
        *)
            echo "Investigate SMART evidence and verify backups."
            ;;
    esac
}

severity_alert() {
    local drive="$1" severity="$2" reason="$3"
    local text
    text=$(cat <<EOF
$(severity_heading "$severity")
HOST: \`${HOST_NAME}\`
DRIVE: \`${drive}\`
SEVERITY: \`${severity}\`
EVIDENCE: \`${reason}\`
TIME: \`$(date -Iseconds)\`

$(severity_guidance "$severity")
EOF
)
    tg_send "$text"
}

burst_alert() {
    local drive="$1" severity="$2" reason="$3"
    local i text
    for ((i=1; i<=BURST_COUNT; i++)); do
        text=$(cat <<EOF
$(severity_heading "$severity")
*ALERT ${i}/${BURST_COUNT}*
HOST: \`${HOST_NAME}\`
DRIVE: \`${drive}\`
SEVERITY: \`${severity}\`
EVIDENCE: \`${reason}\`
TIME: \`$(date -Iseconds)\`

$(severity_guidance "$severity")
EOF
)
        tg_send "$text"
        if (( i < BURST_COUNT )); then
            sleep "$BURST_DELAY"
        fi
    done
}

reminder_alert() {
    local drive="$1" severity="$2" reason="$3"
    local text
    text=$(cat <<EOF
$(severity_heading "$severity") — *REMINDER*
HOST: \`${HOST_NAME}\`
DRIVE: \`${drive}\`
SEVERITY: \`${severity}\`
EVIDENCE: \`${reason}\`
TIME: \`$(date -Iseconds)\`

Finding persists. This message repeats every $((REMINDER_INTERVAL/3600))h while non-OK.
$(severity_guidance "$severity")
EOF
)
    tg_send "$text"
}

recovery_alert() {
    local drive="$1"
    local text
    text=$(cat <<EOF
✅ *DRIVE RECOVERED* — \`${drive}\`
HOST: \`${HOST_NAME}\`
TIME: \`$(date -Iseconds)\`

SMART status returned to OK. Still recommend investigation.
EOF
)
    tg_send "$text"
}

scan_once() {
    local now drive result status severity reason last_status last_severity last_reason last_alert action alert_time
    local all_ok=1
    now="$(date +%s)"

    local -a drives_arr
    mapfile -t drives_arr < <(load_drives)

    for drive in "${drives_arr[@]}"; do
        [[ -z "$drive" ]] && continue

        result="$("$SMART_CHECK_BIN" "$drive")"
        log "scan: $result"

        smart_parse_result "$result"
        status="$SMART_RESULT_STATUS"
        severity="$SMART_RESULT_SEVERITY"
        reason="$SMART_RESULT_REASON"

        last_status="$(state_get "$drive" status)"
        last_severity="$(state_get "$drive" severity)"
        last_reason="$(state_get "$drive" reason)"
        last_alert="$(state_get "$drive" last_alert)"
        [[ -z "$last_alert" ]] && last_alert=0
        if [[ -z "$last_severity" ]]; then
            [[ "$last_status" == "OK" ]] && last_severity="ok" || last_severity="$severity"
        fi
        if [[ -z "$last_reason" && -n "$last_status" && "$last_status" != "OK" ]]; then
            last_reason="$reason"
        fi

        action="$(smart_alert_action "$SMART_POLICY" "$status" "$severity" "$reason" "$last_status" "$last_severity" "$last_reason" "$last_alert" "$now" "$REMINDER_INTERVAL")"
        alert_time="$last_alert"

        if [[ "$status" != "OK" ]]; then
            all_ok=0
        fi

        case "$action" in
            burst)
                log "STATE: $drive ${last_severity:-unknown}->${severity} — burst alerting"
                burst_alert "$drive" "$severity" "$reason"
                alert_time="$now"
                ;;
            alert)
                log "STATE: $drive ${last_severity:-unknown}->${severity} — single alert"
                severity_alert "$drive" "$severity" "$reason"
                alert_time="$now"
                ;;
            reminder)
                log "STATE: $drive still ${severity} — reminder alerting"
                reminder_alert "$drive" "$severity" "$reason"
                alert_time="$now"
                ;;
            recovery)
                log "STATE: $drive ${last_severity:-non-OK}->OK — recovery alert"
                recovery_alert "$drive"
                alert_time="$now"
                ;;
            none)
                [[ "$status" != "OK" ]] && log "STATE: $drive still ${severity} — within reminder window, no alert"
                ;;
        esac

        state_set "$drive" "$status" "$severity" "$reason" "$alert_time"
    done

    # Heartbeat: every HEARTBEAT_EVERY scans, if all drives OK, send "awesome".
    local scan_count
    scan_count="$(meta_get scan_count)"
    [[ -z "$scan_count" || ! "$scan_count" =~ ^[0-9]+$ ]] && scan_count=0
    scan_count=$((scan_count + 1))
    meta_set scan_count "$scan_count"

    local n_drives="${#drives_arr[@]}"
    if (( HEARTBEAT_EVERY > 0 )) && (( scan_count % HEARTBEAT_EVERY == 0 )); then
        local hb_enabled
        hb_enabled="$(state_heartbeat_enabled)"
        if [[ "$hb_enabled" == "false" ]]; then
            log "HEARTBEAT: scan #${scan_count} — disabled by user toggle, skipping"
        elif (( n_drives == 0 )); then
            log "HEARTBEAT: scan #${scan_count} — skipped (no drives configured)"
        elif (( all_ok == 1 )); then
            log "HEARTBEAT: scan #${scan_count} — sending awesome msg"
            heartbeat_alert "$n_drives" "$scan_count" "${drives_arr[@]}"
        else
            log "HEARTBEAT: scan #${scan_count} — skipped (not all OK)"
        fi
    fi
}

main() {
    log "smart-watcher starting; host=${HOST_NAME} policy=${SMART_POLICY} interval=${SCAN_INTERVAL}s burst=${BURST_COUNT}@${BURST_DELAY}s reminder=${REMINDER_INTERVAL}s"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        log "FATAL: TELEGRAM_BOT_TOKEN not set"
        exit 1
    fi

    state_init

    local n_drives no_drives_note=""
    n_drives=$(load_drives | wc -l)
    log "monitoring ${n_drives} drives"
    if (( n_drives == 0 )); then
        log "WARNING: no drives configured in ${DRIVES_FILE}; nothing will be checked"
        no_drives_note=$'\n⚠️ No drives configured in drives.conf, so nothing will be checked.'
    fi

    # Launch bot poller in background. It handles /scan etc.
    "${SCRIPTS_DIR}/bot_poller.sh" &
    BOT_PID=$!
    log "bot_poller started pid=${BOT_PID}"

    trap 'log "shutting down"; kill ${BOT_PID} 2>/dev/null; for _ in 1 2 3 4 5; do kill -0 ${BOT_PID} 2>/dev/null || break; sleep 1; done; kill -9 ${BOT_PID} 2>/dev/null; exit 0' SIGTERM SIGINT

    tg_send "👁️ *SMART watcher online* on \`${HOST_NAME}\` — monitoring ${n_drives} drives every $((SCAN_INTERVAL/3600))h. Send /scan for a quick report or /full for raw output.${no_drives_note}"

    while true; do
        scan_once || log "scan_once returned non-zero (continuing)"
        log "next scan in ${SCAN_INTERVAL}s"
        # If bot_poller died, restart it.
        if ! kill -0 "$BOT_PID" 2>/dev/null; then
            log "bot_poller died; restarting"
            "${SCRIPTS_DIR}/bot_poller.sh" &
            BOT_PID=$!
        fi
        sleep "$SCAN_INTERVAL"
    done
}

if [[ "${ENTRYPOINT_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
