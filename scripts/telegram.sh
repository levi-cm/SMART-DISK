#!/usr/bin/env bash
# telegram.sh — sources helpers; exposes tg_send "<text>".
# Reads /config/users.conf for chat_ids (one per line, comments with # ok).
# Requires TELEGRAM_BOT_TOKEN env.

set -u

TG_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
USERS_FILE="${USERS_FILE:-/config/users.conf}"

tg_chat_ids() {
    grep -vE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null | tr -d '\r' | awk 'NF'
}

tg_send() {
    local text="$1"
    local chat_id rc
    while IFS= read -r chat_id; do
        [[ -z "$chat_id" ]] && continue
        curl -fsS --compressed --http2 \
            --connect-timeout 5 -m 15 \
            -X POST "${TG_API}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=Markdown" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1 || rc=$?
        if [[ -n "${rc:-}" ]]; then
            echo "[telegram] send FAILED rc=${rc}" >&2
            unset rc
        else
            echo "[telegram] sent"
        fi
    done < <(tg_chat_ids)
}
