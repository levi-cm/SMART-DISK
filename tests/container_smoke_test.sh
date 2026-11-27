#!/usr/bin/env bash
# Offline container smoke test. Builds the image and runs it with
# --network none and the compose hardening flags. A mock Bot API listens on
# the container's own loopback (TELEGRAM_API_BASE points at it) and a fake
# smartctl serves fixture drives. Then checks the messages and the upload the
# mock received. Needs Docker; no network access, token, chat or disk.
# SMOKE_ARTIFACTS=<dir> keeps the captured requests and container log;
# SMOKE_IMAGE=<tag> builds to that tag and keeps the image afterwards.
# shellcheck disable=SC2016 # Backticks are literal Markdown in the attachment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

command -v docker >/dev/null 2>&1 || fail "docker is required for the container smoke test"
docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"

IMAGE="${SMOKE_IMAGE:-smart-watcher-smoke:test-$$}"
NAME="smart-watcher-smoke-$$"
# main builds about 35 MiB uncompressed; the image must not grow much.
MAX_IMAGE_BYTES="${SMOKE_MAX_IMAGE_BYTES:-41943040}"
TOKEN="smoke-test-token"
PORT=8081
AUTH_CHAT=424242
OTHER_CHAT=999
HOST_LABEL='smoke_host*[ci]'
PUNCT_DRIVE='/dev/disk/by-id/ata-Fixture_HDD_[A]*1'
BURST_COUNT=2

work="$(mktemp -d)"
cleanup() {
    if [[ -n "${SMOKE_ARTIFACTS:-}" ]]; then
        mkdir -p "$SMOKE_ARTIFACTS"
        cp -r "${work}/mock" "$SMOKE_ARTIFACTS/" 2>/dev/null || true
        docker logs "$NAME" > "${SMOKE_ARTIFACTS}/container.log" 2>&1 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    if [[ -z "${SMOKE_IMAGE:-}" ]]; then
        docker rmi "$IMAGE" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

echo "container_smoke_test: building ${IMAGE}"
docker build -q -t "$IMAGE" "$ROOT_DIR" >/dev/null

size="$(docker image inspect -f '{{.Size}}' "$IMAGE")"
(( size <= MAX_IMAGE_BYTES )) || fail "image is ${size} bytes, over the ${MAX_IMAGE_BYTES}-byte budget"

# --- Mounted directories. Container root has no DAC override (cap-drop ALL),
# so permissions are set for "other". ---------------------------------------------
smoke="${work}/smoke"
config="${work}/config"
mock="${work}/mock"
state="${work}/state"
mkdir -p "${smoke}/fixtures" "$config" "${mock}/requests" "$state"

cp "${ROOT_DIR}/tests/smoke/start.sh" "${ROOT_DIR}/tests/smoke/mock_bot_api.sh" "$smoke/"
cp "${REPORT_FIXTURES}/ata_healthy.json" "${REPORT_FIXTURES}/nvme_worn.json" "${REPORT_FIXTURES}/ata_critical.json" "${smoke}/fixtures/"
make_fake_smartctl "$smoke"
rm -f "${smoke}/reads.log"
map_drive "$smoke" "$PUNCT_DRIVE" /smoke/fixtures/ata_healthy.json
map_drive "$smoke" /dev/nvme0n1 /smoke/fixtures/nvme_worn.json
map_drive "$smoke" /dev/sdz /smoke/fixtures/ata_critical.json

printf '# fixture drives\n%s\n/dev/nvme0n1\n/dev/sdz\n' "$PUNCT_DRIVE" > "${config}/drives.conf"
printf '# fixture chat\n%s\n' "$AUTH_CHAT" > "${config}/users.conf"

jq -n -c --argjson a "$AUTH_CHAT" --argjson o "$OTHER_CHAT" '
    def msg($id; $chat; $text): {update_id: $id, message: {message_id: $id, chat: {id: $chat, type: "private"}, text: $text}};
    {ok: true, result: [msg(1; $a; "/help"), msg(2; $a; "/scan"), msg(3; $a; "/full@smoke_bot"), msg(4; $o; "/scan")]}' \
    > "${mock}/updates.json"

chmod 755 "$smoke" "${smoke}/fixtures" "$config"
chmod 755 "${smoke}/start.sh" "${smoke}/mock_bot_api.sh" "${smoke}/smartctl"
chmod 644 "${smoke}/fixtures/"*.json "${smoke}/drive_map.tsv" "${config}/"*.conf "${mock}/updates.json"
chmod 777 "$mock" "${mock}/requests" "$state"

docker run -d --name "$NAME" \
    --network none --init --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --cap-drop ALL --cap-add SYS_RAWIO --cap-add SYS_ADMIN \
    --security-opt no-new-privileges:true \
    -v "${smoke}:/smoke:ro" -v "${config}:/config:ro" -v "${state}:/state" -v "${mock}:/mock" \
    -e TELEGRAM_BOT_TOKEN="$TOKEN" \
    -e TELEGRAM_API_BASE="http://127.0.0.1:${PORT}" \
    -e MOCK_TOKEN="$TOKEN" -e MOCK_OUT=/mock -e MOCK_PORT="$PORT" \
    -e SMARTCTL_BIN=/smoke/smartctl -e FAKE_SMARTCTL_LOG=/mock/reads.log \
    -e HOST_NAME="$HOST_LABEL" -e SMART_POLICY=paranoid \
    -e BURST_COUNT="$BURST_COUNT" -e BURST_DELAY=0 -e SCAN_INTERVAL=86400 -e POLL_TIMEOUT=1 \
    --entrypoint /smoke/start.sh \
    "$IMAGE" >/dev/null

assert_eq "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$NAME")" "none" "container network mode"

# --- Decode what the mock received ---------------------------------------------------
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# form_field <urlencoded body file> <name>
form_field() {
    local pair
    local -a pairs=()
    IFS='&' read -r -a pairs < "$1" || true
    for pair in "${pairs[@]}"; do
        if [[ "${pair%%=*}" == "$2" ]]; then
            urldecode "${pair#*=}"
            return 0
        fi
    done
    return 1
}

# multipart_field <body file> <boundary> <name>
multipart_field() {
    awk -v delim="--$2" -v want="name=\"$3\"" '
        { sub(/\r$/, "") }
        index($0, delim) == 1 { head = 1; take = 0; next }
        head && $0 == "" { head = 0; next }
        head { if (index($0, want)) take = 1; next }
        take { print }
    ' "$1"
}

# messages: every sendMessage as JSON lines {chat, text, parse_mode}, in order.
messages() {
    local body chat text pm
    for body in "${mock}/requests/"*-sendMessage.body; do
        [[ -e "$body" ]] || continue
        chat="$(form_field "$body" chat_id || true)"
        text="$(form_field "$body" text || true)"
        pm="$(form_field "$body" parse_mode || true)"
        jq -n -c --arg chat "$chat" --arg text "$text" --arg pm "$pm" '{chat: $chat, text: $text, parse_mode: $pm}'
    done
}

# --- Wait for the scheduled scan's alerts and all four commands -----------------------
done_waiting=0
for _ in $(seq 1 120); do
    msgs="$(messages)"
    alerts="$(jq -s '[.[] | select(.parse_mode == "Markdown" and (.text | contains("*ALERT ")))] | length' <<< "$msgs")"
    other="$(jq -s --arg o "$OTHER_CHAT" '[.[] | select(.chat == $o)] | length' <<< "$msgs")"
    docs="$(find "${mock}/requests" -name '*-sendDocument.body' | wc -l)"
    if (( alerts >= 2 * BURST_COUNT && other >= 1 && docs >= 1 )); then
        done_waiting=1
        break
    fi
    sleep 0.5
done
if (( done_waiting == 0 )); then
    docker logs "$NAME" >&2 || true
    fail "timed out waiting for the container's messages"
fi
sleep 1
msgs="$(messages)"

assert_eq "$(docker inspect -f '{{.State.Running}}' "$NAME")" "true" "container still running"
assert_eq "$(docker exec "$NAME" sh -c 'ls -A /tmp')" "" "temp files left in /tmp"

# Every request carried the token; nothing hit the 404 path.
while IFS= read -r line; do
    [[ "$line" == *" /bot${TOKEN}/"* ]] || fail "request without the expected token path: ${line%% HTTP*}"
done < <(head -q -n 1 "${mock}/requests/"*.meta)

# --- Command menu and /help come from one list ----------------------------------------
menu_body="$(find "${mock}/requests" -name '*-setMyCommands.body' | sort | head -n 1)"
[[ -n "$menu_body" ]] || fail "setMyCommands was not called"
menu="$(form_field "$menu_body" commands)"
assert_eq "$(jq -r 'map(.command) | join(",")' <<< "$menu")" "scan,full,heartbeat,help" "registered commands"

# --- Replies to the authorized chat: plain text ------------------------------------------
plain="$(jq -s -c --arg a "$AUTH_CHAT" '[.[] | select(.chat == $a and .parse_mode == "")]' <<< "$msgs")"
assert_eq "$(jq length <<< "$plain")" "5" "plain replies (help, scan ack + report, full ack + cards)"
reply() { jq -r --argjson i "$1" '.[$i].text' <<< "$plain"; }

help="$(reply 0)"
assert_eq "$(grep -E '^/[a-z]+ — ' <<< "$help")" "$(jq -r '.[] | "/\(.command) — \(.description)"' <<< "$menu")" "/help matches the menu"
assert_eq "$(reply 1)" "🔍 Scanning 3 drives on ${HOST_LABEL}…" "/scan acknowledgement"
scan="$(reply 2)"
assert_contains "$scan" "🔴 SMART scan · ${HOST_LABEL}" "/scan title"
assert_contains "$scan" "Worst: CRITICAL · 3 drives" "/scan worst severity"
assert_contains "$scan" "🟢 1 good · 🟠 1 degraded · 🔴 1 critical" "/scan counts"
assert_contains "$scan" "🟢 ${PUNCT_DRIVE} — GOOD" "/scan literal drive path"
assert_contains "$scan" "   🌡 34 °C · ⏱ 12,345 h (1.4 y)" "/scan temperature and hours"
assert_contains "$scan" "   Wear  ▰▰▰▰▰▰▰▰▰▰ 117% used · past rated endurance" "/scan wear gauge"
assert_contains "$scan" "   Spare ▰▰▰▰▰▰▰▰▰▰ 100% (min 10%)" "/scan spare gauge"
assert_contains "$scan" "   • Offline_Uncorrectable(198)=1" "/scan evidence"
assert_eq "$(reply 3)" "🔍 Full scan of 3 drives on ${HOST_LABEL}… the raw output follows as a file." "/full acknowledgement"
cards="$(reply 4)"
assert_contains "$cards" "🔴 SMART full report · ${HOST_LABEL}" "/full title"
assert_contains "$cards" "   • Current_Pending_Sector(197)=2" "/full evidence"

# --- Scheduled alerts keep their Markdown format and burst size --------------------------
markdown="$(jq -s -c --arg a "$AUTH_CHAT" '[.[] | select(.chat == $a and .parse_mode == "Markdown")]' <<< "$msgs")"
assert_eq "$(jq '[.[] | select(.text | contains("SMART watcher online"))] | length' <<< "$markdown")" "1" "startup message"
assert_eq "$(jq '[.[] | select(.text | contains("*ALERT "))] | length' <<< "$markdown")" "$((2 * BURST_COUNT))" "burst alerts"
assert_eq "$(jq '[.[] | select(.text | contains("EVERYTHING AWESOME"))] | length' <<< "$markdown")" "0" "heartbeat with failing drives"

# --- Unauthorized chat ----------------------------------------------------------------------
other="$(jq -s -c --arg o "$OTHER_CHAT" '[.[] | select(.chat == $o)]' <<< "$msgs")"
assert_eq "$(jq length <<< "$other")" "1" "replies to the unauthorized chat"
assert_eq "$(jq -r '.[0].text' <<< "$other")" "⛔ unauthorized chat id: ${OTHER_CHAT}" "unauthorized reply"

# --- The /full upload --------------------------------------------------------------------------
docs=("${mock}/requests/"*-sendDocument.body)
assert_eq "${#docs[@]}" "1" "documents uploaded"
doc_body="${docs[0]}"
content_type="$(sed -n 2p "${doc_body%.body}.meta")"
boundary="${content_type##*boundary=}"
[[ -n "$boundary" && "$boundary" != "$content_type" ]] || fail "upload is not multipart: ${content_type}"
assert_eq "$(multipart_field "$doc_body" "$boundary" chat_id)" "$AUTH_CHAT" "upload chat"
assert_eq "$(multipart_field "$doc_body" "$boundary" caption)" "📄 Full SMART report · ${HOST_LABEL} · worst: CRITICAL" "upload caption"
assert_eq "$(multipart_field "$doc_body" "$boundary" parse_mode)" "" "upload parse_mode"
grep -Eq 'name="document"; filename="smart-full-smoke_host__ci_-[0-9]{8}-[0-9]{6}\.md"' "$doc_body" \
    || fail "upload filename: $(grep -o 'filename="[^"]*"' "$doc_body")"
attachment="$(multipart_field "$doc_body" "$boundary" document)"
assert_contains "$attachment" "# SMART full report" "attachment heading"
assert_contains "$attachment" "$cards" "attachment repeats the cards"
assert_contains "$attachment" '- `Current_Pending_Sector(197)=2`' "attachment evidence"
assert_contains "$attachment" '- `nvme_percentage_used=117>=80`' "attachment NVMe evidence"
assert_contains "$attachment" "=== START OF READ SMART DATA SECTION ===" "attachment raw smartctl text"
assert_contains "$attachment" "Model Number:                       Fixture NVMe 2TB" "attachment raw NVMe text"

# --- One snapshot per drive per report ------------------------------------------------------------
for drive in "$PUNCT_DRIVE" /dev/nvme0n1 /dev/sdz; do
    assert_eq "$(reads_of "${mock}/reads.log" "$drive" "--json=o")" "2" "report reads of ${drive} (one /scan, one /full)"
    assert_eq "$(reads_of "${mock}/reads.log" "$drive" "-a -j")" "1" "scheduled-scan reads of ${drive}"
done

echo "container_smoke_test: ok"
