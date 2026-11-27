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
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/report_lib.sh"

DRIVES_FILE="${DRIVES_FILE:-/config/drives.conf}"
USERS_FILE="${USERS_FILE:-/config/users.conf}"
SMART_CHECK_BIN="${SMART_CHECK_BIN:-${SCRIPTS_DIR}/smart_check.sh}"
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
SMART_POLICY="${SMART_POLICY:-paranoid}"
HOST_NAME="${HOST_NAME:-$(hostname)}"
SCAN_INTERVAL="${SCAN_INTERVAL:-21600}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-4}"
POLL_TIMEOUT="${POLL_TIMEOUT:-25}"

# The only list of bot commands: "name|description". /help and the Telegram
# command menu (setMyCommands) are both generated from it.
BOT_COMMANDS=(
    "scan|Quick visual SMART report for every drive"
    "full|Visual report plus raw smartctl output as a file"
    "heartbeat|Turn the healthy heartbeat message on or off"
    "help|Show the available commands"
)

log() {
    echo "[bot] [$(date -Iseconds)] $*"
}

is_authorized() {
    local id
    while IFS= read -r id; do
        [[ "$id" == "$1" ]] && return 0
    done < <(tg_chat_ids)
    return 1
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
    state_heartbeat_enabled
}

set_heartbeat_enabled() {
    local val="$1"  # "true" or "false"
    if [[ "$val" == "true" ]]; then
        state_apply '._meta = (._meta // {}) | ._meta.heartbeat_enabled = true'
    else
        state_apply '._meta = (._meta // {}) | ._meta.heartbeat_enabled = false'
    fi
}

# ===== Telegram helpers (Markdown UI for the heartbeat keyboard) =====

tg_send_with_keyboard() {
    local chat_id="$1" text="$2" keyboard="$3"
    tg_api sendMessage 20 \
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
    tg_api editMessageText 20 \
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
    tg_api answerCallbackQuery 15 \
        --data-urlencode "callback_query_id=${cb_id}" \
        --data-urlencode "text=${alert_text}" \
        --data-urlencode "show_alert=${show_alert}" \
        >/dev/null 2>&1 \
        || log "tg_answer_callback failed"
}

# ===== Commands menu + help (both from BOT_COMMANDS) =====

bot_commands_json() {
    printf '%s\n' "${BOT_COMMANDS[@]}" | jq -n -c --rawfile list /dev/stdin '
        $list | split("\n") | map(select(length > 0) | index("|") as $i
            | {command: .[:$i], description: .[$i + 1:]})'
}

register_commands() {
    if tg_api setMyCommands 15 --data-urlencode "commands=$(bot_commands_json)" >/dev/null 2>&1; then
        log "registered ${#BOT_COMMANDS[@]} bot commands"
    else
        log "setMyCommands failed; command menu not updated"
    fi
}

help_text() {
    local entry
    printf '🤖 SMART Watcher · %s\n\nCommands:\n' "$HOST_NAME"
    for entry in "${BOT_COMMANDS[@]}"; do
        printf '/%s — %s\n' "${entry%%|*}" "${entry#*|}"
    done
    printf '\nAutomatic scan every %sh. Policy: %s. Critical findings always burst; the paranoid policy bursts on every finding.' \
        "$((SCAN_INTERVAL / 3600))" "$SMART_POLICY"
}

handle_help() {
    local chat_id="$1"
    tg_send_text_to "$chat_id" "$(help_text)" || log "help reply failed"
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

# ===== /scan and /full =====

drive_count_label() {
    if [[ "$1" == "1" ]]; then echo "1 drive"; else echo "$1 drives"; fi
}

# handle_report <chat_id> <scan|full>
# One acknowledgement, then the visual report. /full also attaches a Markdown
# file with the evidence and raw smartctl text. Each drive is read once.
handle_report() {
    local chat_id="$1" mode="$2"
    local -a drives
    local n workdir generated text worst caption
    mapfile -t drives < <(load_drives)
    n="${#drives[@]}"
    log "/${mode} from authorized chat (${n} drives)"

    if (( n == 0 )); then
        tg_send_text_to "$chat_id" "🔍 Checking drives on ${HOST_NAME}…" || log "ack failed"
    elif [[ "$mode" == "full" ]]; then
        tg_send_text_to "$chat_id" "🔍 Full scan of $(drive_count_label "$n") on ${HOST_NAME}… the raw output follows as a file." || log "ack failed"
    else
        tg_send_text_to "$chat_id" "🔍 Scanning $(drive_count_label "$n") on ${HOST_NAME}…" || log "ack failed"
    fi

    if ! workdir="$(mktemp -d "${TMPDIR:-/tmp}/smart-${mode}.XXXXXX")"; then
        log "could not create a report temp dir"
        tg_send_text_to "$chat_id" "⚠️ Report failed: could not create a temporary directory." || true
        return
    fi

    generated="$(date -u '+%Y-%m-%d %H:%M UTC')"
    report_collect "$workdir" "${drives[@]}"
    text="$(report_render "$mode" "${workdir}/records.jsonl" "$generated")"
    if [[ -z "$text" ]]; then
        log "/${mode} report render failed"
        text="⚠️ SMART ${mode} on ${HOST_NAME}: the report could not be rendered. Check the container logs."
    fi
    tg_send_text_to "$chat_id" "$text" || log "/${mode} report send failed"

    if [[ "$mode" == "full" ]] && (( n > 0 )); then
        worst="$(report_worst "${workdir}/records.jsonl")"
        report_write_markdown "${workdir}/records.jsonl" "${workdir}/report.md" "$text"
        caption="📄 Full SMART report · ${HOST_NAME} · worst: $(smart_severity_label "$worst")"
        if tg_send_document_to "$chat_id" "${workdir}/report.md" \
            "smart-full-${HOST_NAME}-$(date -u +%Y%m%d-%H%M%S).md" "$caption"; then
            log "/full attachment sent"
        else
            log "/full attachment failed"
        fi
    fi

    rm -rf -- "$workdir"
}

# ===== Dispatch =====

handle_command() {
    local chat_id="$1" text="$2"
    local cmd="${text%% *}"
    cmd="${cmd%@*}"

    if ! is_authorized "$chat_id"; then
        log "unauthorized command rejected"
        tg_send_text_to "$chat_id" "⛔ unauthorized chat id: ${chat_id}" || true
        return
    fi

    case "$cmd" in
        /scan)       handle_report "$chat_id" scan ;;
        /full)       handle_report "$chat_id" full ;;
        /heartbeat)  handle_heartbeat "$chat_id" ;;
        /start|/help) handle_help "$chat_id" ;;
        *)
            log "unhandled cmd=${cmd} from authorized chat"
            tg_send_text_to "$chat_id" "Unknown command: ${cmd}. Try /help." || true
            ;;
    esac
}

main() {
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
        log "FATAL: TELEGRAM_BOT_TOKEN not set"
        exit 1
    fi

    state_init
    register_commands

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
        resp="$(curl "${TG_CURL_OPTS[@]}" -m $((POLL_TIMEOUT + 10)) \
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
