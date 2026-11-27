#!/usr/bin/env bash
# mock_bot_api.sh — tiny Telegram Bot API mock for the offline smoke test.
# busybox `nc -lk -e` runs it once per connection with the socket on stdin and
# stdout. Each request is saved under $MOCK_OUT/requests as <id>-<method>.meta
# (request line + content type) and <id>-<method>.body (raw body).
# The first getUpdates call returns $MOCK_OUT/updates.json; later calls wait a
# second and return no updates. A path without the expected token gets a 404.
set -u
exec 2>>"${MOCK_OUT:?}/mock.err"

token="${MOCK_TOKEN:?}"
requests="${MOCK_OUT}/requests"

respond() {
    local status="$1" body="$2"
    printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "$status" "${#body}" "$body"
}

IFS= read -r request_line || exit 0
request_line="${request_line%$'\r'}"
[[ -z "$request_line" ]] && exit 0
read -r _ target _ <<< "$request_line"

length=0
expect=""
content_type=""
while IFS= read -r header; do
    header="${header%$'\r'}"
    [[ -z "$header" ]] && break
    name="${header%%:*}"
    value="${header#*:}"
    value="${value# }"
    case "${name,,}" in
        content-length) length="$value" ;;
        expect) expect="${value,,}" ;;
        content-type) content_type="$value" ;;
    esac
done

if [[ "$expect" == "100-continue" ]]; then
    printf 'HTTP/1.1 100 Continue\r\n\r\n'
fi

path="${target%%\?*}"
method="${path##*/}"
id="$(date +%s%N)-$$"
printf '%s\n%s\n' "$request_line" "$content_type" > "${requests}/${id}-${method}.meta"
if [[ "$length" =~ ^[0-9]+$ ]] && (( length > 0 )); then
    head -c "$length" > "${requests}/${id}-${method}.body"
else
    : > "${requests}/${id}-${method}.body"
fi

if [[ "$path" != "/bot${token}/${method}" ]]; then
    respond "404 Not Found" '{"ok":false,"error_code":404,"description":"Not Found"}'
    exit 0
fi

case "$method" in
    getUpdates)
        if mv "${MOCK_OUT}/updates.json" "${MOCK_OUT}/updates.served" 2>/dev/null; then
            respond "200 OK" "$(cat "${MOCK_OUT}/updates.served")"
        else
            sleep 1
            respond "200 OK" '{"ok":true,"result":[]}'
        fi
        ;;
    sendMessage|sendDocument|editMessageText)
        respond "200 OK" '{"ok":true,"result":{"message_id":1}}'
        ;;
    *)
        respond "200 OK" '{"ok":true,"result":true}'
        ;;
esac
