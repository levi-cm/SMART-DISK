#!/usr/bin/env bash
# bot_poller.sh — long-polls Telegram getUpdates and dispatches commands + callbacks.
# Authorized chat IDs come from /config/users.conf. Unknown chats are rejected.
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
USERS_FILE="${USERS_FILE:-/config/users.conf}"
SMART_CHECK_BIN="${SMART_CHECK_BIN:-${SCRIPTS_DIR}/smart_check.sh}"
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
SMART_POLICY="${SMART_POLICY:-paranoid}"
HOST_NAME="${HOST_NAME:-$(hostname)}"
SCAN_INTERVAL="${SCAN_INTERVAL:-21600}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-4}"
TG_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
POLL_TIMEOUT="${POLL_TIMEOUT:-25}"
TG_CHUNK_LIMIT="${TG_CHUNK_LIMIT:-3800}"

log() {
    echo "[bot] [$(date -Iseconds)] $*"
}

is_authorized() {
    grep -vE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null | tr -d '\r' | awk 'NF' | grep -qx -- "$1"
}

load_drives() {
    grep -vE '^\s*(#|$)' "$DRIVES_FILE" | tr -d '\r' | awk 'NF'
}

get_last_update_id() {
    local v
    v="$(state_read '._meta.last_update_id // 0')"
    [[ -z "$v" || ! "$v" =~ ^[0-9]+$ ]] && v=0
    echo "$v"
}

set_last_update_id() {
    state_apply '._meta = (._meta // {}) | ._meta.last_update_id = $v' --argjson v "$1"
}

heartbeat_enabled() {
    local v
    v="$(state_read '._meta.heartbeat_enabled // true')"
    [[ "$v" == "false" ]] && echo "false" || echo "true"
}

set_heartbeat_enabled() {
    local val="$1"  # "true" or "false"
    if [[ "$val" == "true" ]]; then
        state_apply '._meta = (._meta // {}) | ._meta.heartbeat_enabled = true'
    else
        state_apply '._meta = (._meta // {}) | ._meta.heartbeat_enabled = false'
    fi
}

# ===== Telegram helpers =====
# All curl invocations share keepalive/http2 flags for TLS reuse.
CURL_BASE=(-fsS --compressed --http2 --connect-timeout 5)

tg_send_to() {
    local chat_id="$1" text="$2"
    curl "${CURL_BASE[@]}" -m 20 -X POST "${TG_API}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null 2>&1 \
        || log "tg_send_to failed"
}

tg_send_with_keyboard() {
    local chat_id="$1" text="$2" keyboard="$3"
    curl "${CURL_BASE[@]}" -m 20 -X POST "${TG_API}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "reply_markup=${keyboard}" \
        >/dev/null 2>&1 \
        || log "tg_send_with_keyboard failed"
}

tg_edit_message() {
    local chat_id="$1" message_id="$2" text="$3" keyboard="$4"
    curl "${CURL_BASE[@]}" -m 20 -X POST "${TG_API}/editMessageText" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "message_id=${message_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "reply_markup=${keyboard}" \
        >/dev/null 2>&1 \
        || log "tg_edit_message failed"
}

tg_answer_callback() {
    local cb_id="$1" alert_text="$2" show_alert="${3:-false}"
    curl "${CURL_BASE[@]}" -m 15 -X POST "${TG_API}/answerCallbackQuery" \
        --data-urlencode "callback_query_id=${cb_id}" \
        --data-urlencode "text=${alert_text}" \
        --data-urlencode "show_alert=${show_alert}" \
        >/dev/null 2>&1 \
        || log "tg_answer_callback failed"
}

tg_send_document() {
    local chat_id="$1" file_path="$2" caption="$3"
    curl "${CURL_BASE[@]}" -m 60 -X POST "${TG_API}/sendDocument" \
        -F "chat_id=${chat_id}" \
        -F "document=@${file_path}" \
        -F "caption=${caption}" \
        -F "parse_mode=Markdown" \
        >/dev/null 2>&1 \
        || log "tg_send_document failed"
}

tg_send_to_plain() {
    local chat_id="$1" text="$2"
    curl "${CURL_BASE[@]}" -m 20 -X POST "${TG_API}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" \
        >/dev/null 2>&1 \
        || log "tg_send_to_plain failed"
}

# Split body into <=TG_CHUNK_LIMIT char chunks on newline boundaries; send each as plain text.
# Returns count of messages sent via stdout.
tg_send_chunked_plain() {
    local chat_id="$1" body="$2"
    local buf="" line count=0
    while IFS= read -r line; do
        if (( ${#buf} + ${#line} + 1 > TG_CHUNK_LIMIT )); then
            tg_send_to_plain "$chat_id" "$buf"
            count=$((count + 1))
            buf=""
        fi
        if [[ -n "$buf" ]]; then
            buf+=$'\n'
        fi
        buf+="$line"
    done <<< "$body"
    if [[ -n "$buf" ]]; then
        tg_send_to_plain "$chat_id" "$buf"
        count=$((count + 1))
    fi
    echo "$count"
}

# ===== Heartbeat command =====

heartbeat_keyboard() {
    cat <<'JSON'
{"inline_keyboard":[[{"text":"✅ Enable","callback_data":"hb:on"},{"text":"❌ Disable","callback_data":"hb:off"},{"text":"ℹ️ Status","callback_data":"hb:status"}]]}
JSON
}

heartbeat_status_text() {
    local state
    state="$(heartbeat_enabled)"
    local human="❌ *DISABLED* — only non-OK SMART alerts will be sent."
    [[ "$state" == "true" ]] && human="✅ *ENABLED* — daily 'everything awesome' messages active."

    cat <<EOF
🫀 *Heartbeat (everything-awesome) toggle*

Current: ${human}

Cadence when enabled: every ${HEARTBEAT_EVERY} scans = $((HEARTBEAT_EVERY * SCAN_INTERVAL / 3600))h.

Pick an action below.
EOF
}

handle_heartbeat() {
    local chat_id="$1"
    log "/heartbeat from authorized chat"
    tg_send_with_keyboard "$chat_id" "$(heartbeat_status_text)" "$(heartbeat_keyboard)"
}

handle_callback() {
    local cb_id="$1" from_id="$2" chat_id="$3" message_id="$4" data="$5"

    if ! is_authorized "$from_id"; then
        log "unauthorized callback rejected"
        tg_answer_callback "$cb_id" "⛔ unauthorized" "true"
        return
    fi

    case "$data" in
        hb:on)
            set_heartbeat_enabled true
            tg_answer_callback "$cb_id" "✅ Heartbeat ENABLED" "true"
            tg_edit_message "$chat_id" "$message_id" "$(heartbeat_status_text)" "$(heartbeat_keyboard)"
            ;;
        hb:off)
            set_heartbeat_enabled false
            tg_answer_callback "$cb_id" "❌ Heartbeat DISABLED — only bad-news messages from now on." "true"
            tg_edit_message "$chat_id" "$message_id" "$(heartbeat_status_text)" "$(heartbeat_keyboard)"
            ;;
        hb:status)
            local state
            state="$(heartbeat_enabled)"
            if [[ "$state" == "true" ]]; then
                tg_answer_callback "$cb_id" "Heartbeat is currently ENABLED" "true"
            else
                tg_answer_callback "$cb_id" "Heartbeat is currently DISABLED" "true"
            fi
            ;;
        *)
            log "unknown callback data=${data}"
            tg_answer_callback "$cb_id" "Unknown action" "false"
            ;;
    esac
}

# ===== Scan command =====

# Build markdown report file at $1; return highest severity via stdout.
build_scan_report() {
    local out="$1"
    local drive verdict severity reason full rank icon label
    local highest_rank=0 overall="ok"
    local now
    now="$(date -Iseconds)"

    {
        echo "# SMART Scan Report"
        echo ""
        echo "- **Host:** \`${HOST_NAME}\`"
        echo "- **Generated:** \`${now}\`"
        echo ""
    } > "$out"

    local per_drive_summary=""
    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        verdict="$("$SMART_CHECK_BIN" "$drive")"
        smart_parse_result "$verdict"
        severity="$SMART_RESULT_SEVERITY"
        reason="$SMART_RESULT_REASON"
        rank="$(smart_severity_rank "$severity")"
        icon="$(smart_severity_icon "$severity")"
        label="$(smart_severity_label "$severity")"
        (( rank > highest_rank )) && highest_rank="$rank"

        if [[ "$severity" == "ok" ]]; then
            per_drive_summary+="- 🟢 \`${drive}\` — **GOOD**"$'\n'
        else
            per_drive_summary+="- ${icon} \`${drive}\` — **${label}**: ${reason}"$'\n'
        fi

        full="$("$SMARTCTL_BIN" -a "$drive" 2>&1 || true)"

        {
            echo ""
            if [[ "$severity" != "ok" ]]; then
                echo "## ${icon} ${drive} — ${label}"
                echo ""
                echo "**Evidence:** \`${reason}\`"
            else
                echo "## 🟢 ${drive} — GOOD"
            fi
            echo ""
            echo '```'
            echo "$full"
            echo '```'
        } >> "$out"
    done < <(load_drives)

    {
        echo ""
        echo "## Summary"
        echo ""
        echo "$per_drive_summary"
        case "$highest_rank" in
            3) echo "**Overall: 🔴 CRITICAL FINDINGS**" ;;
            2) echo "**Overall: 🟠 DEGRADED HEALTH**" ;;
            1) echo "**Overall: 🟡 ADVISORIES REQUIRE REVIEW**" ;;
            *) echo "**Overall: ✅ ALL DRIVES HEALTHY**" ;;
        esac
    } >> "$out"

    case "$highest_rank" in
        3) overall="critical" ;;
        2) overall="degraded" ;;
        1) overall="advisory" ;;
    esac
    echo "$overall"
}

handle_scan() {
    local chat_id="$1"
    log "/scan from authorized chat"
    tg_send_to "$chat_id" "🔍 *Scanning drives on* \`${HOST_NAME}\` *...*"

    local ts file overall caption
    ts="$(date +%Y%m%d-%H%M%S)"
    file="/tmp/smart-scan-${HOST_NAME}-${ts}.md"

    # Build full markdown report up front (used as fallback attachment).
    overall="$(build_scan_report "$file")"

    # Send per-drive: header verdict, then chunked plain-text smartctl -a output.
    local drive verdict severity reason icon label full any_split=0 chunks
    while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        verdict="$("$SMART_CHECK_BIN" "$drive")"
        smart_parse_result "$verdict"
        severity="$SMART_RESULT_SEVERITY"
        reason="$SMART_RESULT_REASON"
        icon="$(smart_severity_icon "$severity")"
        label="$(smart_severity_label "$severity")"

        if [[ "$severity" == "ok" ]]; then
            tg_send_to "$chat_id" "🟢 *${drive} — GOOD*"
        else
            tg_send_to "$chat_id" "${icon} *${drive} — ${label}*"$'\n'"evidence: \`${reason}\`"
        fi

        full="$("$SMARTCTL_BIN" -a "$drive" 2>&1 || true)"
        chunks="$(tg_send_chunked_plain "$chat_id" "===== ${drive} =====
${full}")"
        log "drive=${drive} chunks=${chunks}"
        if [[ "$chunks" =~ ^[0-9]+$ ]] && (( chunks > 1 )); then
            any_split=1
        fi
    done < <(load_drives)

    # Final verdict.
    case "$overall" in
        critical)
            tg_send_to "$chat_id" "🔴 *SCAN COMPLETE — CRITICAL FINDINGS*"
            caption="🔴 Full SMART scan report — CRITICAL on ${HOST_NAME}"
            ;;
        degraded)
            tg_send_to "$chat_id" "🟠 *SCAN COMPLETE — DEGRADED HEALTH*"
            caption="🟠 Full SMART scan report — DEGRADED on ${HOST_NAME}"
            ;;
        advisory)
            tg_send_to "$chat_id" "🟡 *SCAN COMPLETE — ADVISORIES REQUIRE REVIEW*"
            caption="🟡 Full SMART scan report — ADVISORY on ${HOST_NAME}"
            ;;
        *)
            tg_send_to "$chat_id" "✅ *SCAN COMPLETE — ALL DRIVES HEALTHY*"
            caption="📄 Full SMART scan report — ${HOST_NAME}"
            ;;
    esac

    # If any drive output had to be split, also attach the consolidated .md at the end.
    if (( any_split == 1 )); then
        log "output was chunked; attaching .md report"
        tg_send_document "$chat_id" "$file" "$caption"
    else
        log "all output fit single messages; skipping .md attachment"
    fi

    rm -f "$file"
}

# ===== Help =====

handle_help() {
    local chat_id="$1"
    tg_send_to "$chat_id" "*SMART Watcher* — host \`${HOST_NAME}\`

Commands:
\`/scan\` — run scan now, full SMART output as \`.md\` file
\`/heartbeat\` — toggle daily 'everything awesome' messages on/off (popup keyboard)
\`/help\` — show this message

Automatic scan runs every $((SCAN_INTERVAL/3600))h. Policy: \`${SMART_POLICY}\`. Critical findings always burst; paranoid policy bursts on every finding."
}

# ===== Dispatch =====

handle_command() {
    local chat_id="$1" text="$2"
    local cmd="${text%% *}"
    cmd="${cmd%@*}"

    if ! is_authorized "$chat_id"; then
        log "unauthorized command rejected"
        tg_send_to "$chat_id" "⛔ unauthorized chat id: \`${chat_id}\`"
        return
    fi

    case "$cmd" in
        /scan)       handle_scan "$chat_id" ;;
        /heartbeat)  handle_heartbeat "$chat_id" ;;
        /start|/help) handle_help "$chat_id" ;;
        *)
            log "unhandled cmd=${cmd} from authorized chat"
            tg_send_to "$chat_id" "Unknown command: \`${cmd}\`. Try \`/help\`."
            ;;
    esac
}

main() {
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        log "FATAL: TELEGRAM_BOT_TOKEN not set"
        exit 1
    fi

    state_init

    local offset
    offset="$(get_last_update_id)"
    offset=$((offset + 1))
    log "starting; offset=${offset}"

    # allowed_updates=["message","callback_query"] urlencoded
    local allowed='%5B%22message%22%2C%22callback_query%22%5D'

    # Field separator (US, 0x1f) emitted by jq between fields; NUL between records.
    local US
    US=$'\037'
    local backoff=0

    while true; do
        local resp ok max_upd_id=0
        resp="$(curl "${CURL_BASE[@]}" -m $((POLL_TIMEOUT + 10)) \
            "${TG_API}/getUpdates?offset=${offset}&timeout=${POLL_TIMEOUT}&allowed_updates=${allowed}" \
            2>/dev/null)" || resp=""

        if [[ -z "$resp" ]]; then
            (( backoff < 30 )) && backoff=$((backoff + 5))
            sleep "$backoff"
            continue
        fi

        # Single .ok check; skips per-update parsing entirely on API error.
        ok="$(jq -r '.ok // false' <<< "$resp" 2>/dev/null)"
        if [[ "$ok" != "true" ]]; then
            log "getUpdates not ok: $resp"
            (( backoff < 30 )) && backoff=$((backoff + 10))
            sleep "$backoff"
            continue
        fi
        backoff=0

        # Stream all updates from a single jq pass via process substitution.
        # NUL-terminated records, US-separated fields. Bash $(...) would strip
        # NULs, so we pipe directly into the read loop.
        local upd_id text chat_id cb_id from_id cb_chat_id cb_msg_id cb_data
        while IFS="$US" read -r -d '' upd_id text chat_id cb_id from_id cb_chat_id cb_msg_id cb_data; do
            [[ -z "$upd_id" || ! "$upd_id" =~ ^[0-9]+$ ]] && continue
            (( upd_id > max_upd_id )) && max_upd_id=$upd_id
            offset=$((upd_id + 1))

            if [[ -n "$text" && -n "$chat_id" ]]; then
                handle_command "$chat_id" "$text"
                continue
            fi

            if [[ -n "$cb_id" ]]; then
                handle_callback "$cb_id" "$from_id" "$cb_chat_id" "$cb_msg_id" "$cb_data"
                continue
            fi
        done < <(jq -j -f "${SCRIPTS_DIR}/parse_updates.jq" <<< "$resp" 2>/dev/null)

        # Persist offset once after the whole batch — one jq fork per poll
        # instead of one per update. On crash mid-batch, Telegram redelivers
        # unACKed updates; handlers are idempotent.
        if (( max_upd_id > 0 )); then
            set_last_update_id "$max_upd_id"
        fi
    done
}

if [[ "${BOT_POLLER_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
