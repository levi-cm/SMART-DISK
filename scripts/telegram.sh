#!/usr/bin/env bash
# telegram.sh — shared Telegram Bot API helpers.
# Chat IDs come from /config/users.conf (one per line, comments with # ok).
# Requires TELEGRAM_BOT_TOKEN. TELEGRAM_API_BASE overrides the API host, for a
# self-hosted Bot API server or the offline smoke test.

set -u

SCRIPTS_DIR="${SCRIPTS_DIR:-/scripts}"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/config_lib.sh"

TELEGRAM_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
TG_API="${TELEGRAM_API_BASE%/}/bot${TELEGRAM_BOT_TOKEN:-}"
USERS_FILE="${USERS_FILE:-/config/users.conf}"
# Telegram rejects messages longer than 4096 UTF-16 code units.
TG_MAX_TEXT=4096
TG_CHUNK_LIMIT="${TG_CHUNK_LIMIT:-3800}"
TG_CURL_OPTS=(-fsS --compressed --http2 --connect-timeout 5)

tg_chat_ids() {
    conf_lines "$USERS_FILE"
}

# tg_api <method> <max_seconds> [curl args...]
# POSTs to the Bot API and prints the response body. Callers decide whether to
# keep it; never log it, because it can echo chat IDs and message text.
tg_api() {
    local method="$1" max_time="$2"
    shift 2
    curl "${TG_CURL_OPTS[@]}" -m "$max_time" -X POST "${TG_API}/${method}" "$@"
}

# tg_chunk_limit: TG_CHUNK_LIMIT clamped to 16..4096.
tg_chunk_limit() {
    local limit="$TG_CHUNK_LIMIT"
    if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit > TG_MAX_TEXT )); then
        limit="$TG_MAX_TEXT"
    elif (( limit < 16 )); then
        limit=16
    fi
    echo "$limit"
}

# tg_split_text <text>
# Prints NUL-terminated chunks that each fit in one message. Splits at blank
# lines first, then at line ends, then inside an over-long line. Chunks with
# no visible characters are dropped, so an empty message is never produced.
tg_split_text() {
    printf '%s' "$1" | jq -n -j --rawfile text /dev/stdin --argjson limit "$(tg_chunk_limit)" \
        -f "${SCRIPTS_DIR}/tg_split.jq"
}

# tg_send_text_to <chat_id> <text>
# Sends plain text (no parse_mode), so drive paths, host labels and model
# names display literally whatever punctuation they contain. Long text is
# split. Returns non-zero if any part failed.
tg_send_text_to() {
    local chat_id="$1" text="$2" chunk rc=0 parts=0
    while IFS= read -r -d '' chunk; do
        parts=$((parts + 1))
        if ! tg_api sendMessage 20 \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${chunk}" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1; then
            echo "[telegram] sendMessage failed" >&2
            rc=1
        fi
    done < <(tg_split_text "$text")
    if (( parts == 0 )) && [[ "$text" =~ [^[:space:]] ]]; then
        echo "[telegram] could not split message text" >&2
        rc=1
    fi
    return "$rc"
}

# tg_send_document_to <chat_id> <file> <upload_name> <caption>
# Uploads a Markdown file with a plain-text caption. --form-string keeps curl
# from interpreting ';type=' or a leading '@' in the caption.
tg_send_document_to() {
    local chat_id="$1" file="$2" name="$3" caption="$4"
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    # Telegram allows 1024 caption characters; cut by code point, not byte.
    caption="$(jq -n -r --arg c "$caption" '$c[:1000]')"
    tg_api sendDocument 60 \
        --form-string "chat_id=${chat_id}" \
        --form-string "caption=${caption}" \
        -F "document=@${file};filename=${name};type=text/markdown" \
        >/dev/null 2>&1
}

# tg_send <text>
# Broadcasts a Markdown alert to every chat in users.conf.
tg_send() {
    local text="$1"
    local chat_id rc
    while IFS= read -r chat_id; do
        [[ -z "$chat_id" ]] && continue
        tg_api sendMessage 15 \
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
