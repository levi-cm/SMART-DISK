#!/usr/bin/env bash
# entrypoint.sh — main loop.
# Polls each drive in /config/drives.conf every $SCAN_INTERVAL seconds.
# Maintains /state/last_status.json to drive state-machine alerts.
# shellcheck disable=SC2016

set -uo pipefail

# shellcheck source=/dev/null
source /scripts/telegram.sh
# shellcheck source=/dev/null
source /scripts/state_lib.sh

DRIVES_FILE="${DRIVES_FILE:-/config/drives.conf}"
SCAN_INTERVAL="${SCAN_INTERVAL:-21600}"
BURST_COUNT="${BURST_COUNT:-10}"
BURST_DELAY="${BURST_DELAY:-30}"
REMINDER_INTERVAL="${REMINDER_INTERVAL:-86400}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-4}"
HOST_NAME="${HOST_NAME:-$(hostname)}"

log() {
    echo "[$(date -Iseconds)] $*"
}

# Load drives (skip blanks/comments).
load_drives() {
    grep -vE '^\s*(#|$)' "$DRIVES_FILE" | tr -d '\r' | awk 'NF'
}

# state_get <drive> <field>  (field: status|last_alert)
state_get() {
    state_read '.[$d][$f] // empty' --arg d "$1" --arg f "$2"
}

# state_set <drive> <status> <last_alert_epoch>
state_set() {
    state_apply '.[$d] = {status: $s, last_alert: $t}' \
        --arg d "$1" --arg s "$2" --argjson t "$3"
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

burst_alert() {
    local drive="$1" reason="$2"
    local i text
    for ((i=1; i<=BURST_COUNT; i++)); do
        text=$(cat <<EOF
🚨🚨🚨 *DRIVE FAILURE* 🚨🚨🚨
*ALERT ${i}/${BURST_COUNT}*
HOST: \`${HOST_NAME}\`
DRIVE: \`${drive}\`
REASON: \`${reason}\`
TIME: \`$(date -Iseconds)\`

⚠️ ACT NOW. CHECK BACKUPS. PLAN REPLACEMENT. ⚠️
EOF
)
        tg_send "$text"
        if (( i < BURST_COUNT )); then
            sleep "$BURST_DELAY"
        fi
    done
}

reminder_alert() {
    local drive="$1" reason="$2"
    local text
    text=$(cat <<EOF
😡 *STILL FAILING — ${drive}* 😡
HOST: \`${HOST_NAME}\`
REASON: \`${reason}\`
TIME: \`$(date -Iseconds)\`

Drive *still* in failed state. Replace it. This message repeats every $((REMINDER_INTERVAL/3600))h while degraded.
EOF
)
    tg_send "$text"
}

recovery_alert() {
    local drive="$1"
    local text
    text=$(cat <<EOF
✅ *DRIVE RECOVERED* — ${drive}
HOST: \`${HOST_NAME}\`
TIME: \`$(date -Iseconds)\`

SMART status returned to OK. Still recommend investigation.
EOF
)
    tg_send "$text"
}

scan_once() {
    local now drive result status reason last_status last_alert
    local all_ok=1
    now="$(date +%s)"

    local -a drives_arr
    mapfile -t drives_arr < <(load_drives)

    for drive in "${drives_arr[@]}"; do
        [[ -z "$drive" ]] && continue

        result="$(/scripts/smart_check.sh "$drive")"
        log "scan: $result"

        # Parse "OK <drive>" or "FAIL <drive> <reason>" without forking
        read -r status _ reason <<< "$result"
        [[ -z "$reason" ]] && reason="-"

        last_status="$(state_get "$drive" status)"
        last_alert="$(state_get "$drive" last_alert)"
        [[ -z "$last_alert" ]] && last_alert=0

        if [[ "$status" == "FAIL" ]]; then
            all_ok=0
            if [[ "$last_status" != "FAIL" ]]; then
                log "STATE: $drive OK->FAIL — burst alerting"
                burst_alert "$drive" "$reason"
                state_set "$drive" "FAIL" "$now"
            else
                if (( now - last_alert >= REMINDER_INTERVAL )); then
                    log "STATE: $drive still FAIL — reminder alerting"
                    reminder_alert "$drive" "$reason"
                    state_set "$drive" "FAIL" "$now"
                else
                    log "STATE: $drive still FAIL — within reminder window, no alert"
                fi
            fi
        else
            if [[ "$last_status" == "FAIL" ]]; then
                log "STATE: $drive FAIL->OK — recovery alert"
                recovery_alert "$drive"
            fi
            state_set "$drive" "OK" "$now"
        fi
    done

    # Heartbeat: every HEARTBEAT_EVERY scans, if all drives OK, send "awesome".
    local scan_count
    scan_count="$(meta_get scan_count)"
    [[ -z "$scan_count" || ! "$scan_count" =~ ^[0-9]+$ ]] && scan_count=0
    scan_count=$((scan_count + 1))
    meta_set scan_count "$scan_count"

    if (( HEARTBEAT_EVERY > 0 )) && (( scan_count % HEARTBEAT_EVERY == 0 )); then
        local hb_enabled
        hb_enabled="$(state_read '._meta.heartbeat_enabled // true')"
        if [[ "$hb_enabled" == "false" ]]; then
            log "HEARTBEAT: scan #${scan_count} — disabled by user toggle, skipping"
        elif (( all_ok == 1 )); then
            local n_drives="${#drives_arr[@]}"
            log "HEARTBEAT: scan #${scan_count} — sending awesome msg"
            heartbeat_alert "$n_drives" "$scan_count" "${drives_arr[@]}"
        else
            log "HEARTBEAT: scan #${scan_count} — skipped (not all OK)"
        fi
    fi
}

main() {
    log "smart-watcher starting; host=${HOST_NAME} interval=${SCAN_INTERVAL}s burst=${BURST_COUNT}@${BURST_DELAY}s reminder=${REMINDER_INTERVAL}s"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        log "FATAL: TELEGRAM_BOT_TOKEN not set"
        exit 1
    fi

    state_init

    local n_drives
    n_drives=$(load_drives | wc -l)
    log "monitoring ${n_drives} drives"

    # Launch bot poller in background. It handles /scan etc.
    /scripts/bot_poller.sh &
    BOT_PID=$!
    log "bot_poller started pid=${BOT_PID}"

    trap 'log "shutting down"; kill ${BOT_PID} 2>/dev/null; for _ in 1 2 3 4 5; do kill -0 ${BOT_PID} 2>/dev/null || break; sleep 1; done; kill -9 ${BOT_PID} 2>/dev/null; exit 0' SIGTERM SIGINT

    tg_send "👁️ *SMART watcher online* on \`${HOST_NAME}\` — monitoring ${n_drives} drives every $((SCAN_INTERVAL/3600))h. Send /scan for on-demand report."

    while true; do
        scan_once || log "scan_once returned non-zero (continuing)"
        log "next scan in ${SCAN_INTERVAL}s"
        # If bot_poller died, restart it.
        if ! kill -0 "$BOT_PID" 2>/dev/null; then
            log "bot_poller died; restarting"
            /scripts/bot_poller.sh &
            BOT_PID=$!
        fi
        sleep "$SCAN_INTERVAL"
    done
}

main "$@"
