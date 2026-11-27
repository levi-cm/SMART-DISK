#!/usr/bin/env bash
# Message splitting: no empty messages, nothing over Telegram's 4096 UTF-16
# code-unit limit, even for one huge line or emoji-heavy text.
# shellcheck disable=SC2016 # $i inside single quotes is a jq variable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

export TELEGRAM_BOT_TOKEN="test-token"
export SCRIPTS_DIR="${ROOT_DIR}/scripts"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/telegram.sh"
record_tg_api "$tmpdir"

repeat() {
    local s="$1" n="$2" out=""
    while (( n > 0 )); do
        out+="$s"
        n=$((n - 1))
    done
    printf '%s' "$out"
}

# send_case <name> <limit> <text>
# Sends <text> and checks every message: non-blank, within the limit and
# within 4096 units. Prints the number of messages sent.
send_case() {
    local name="$1" limit="$2" text="$3" count i msg units
    : > "${TG_RECORD_DIR}/calls.jsonl"
    TG_CHUNK_LIMIT="$limit" tg_send_text_to 1001 "$text" || fail "${name}: send reported failure"
    count="$(tg_calls '[.[] | select(.method == "sendMessage")] | length')"
    for (( i = 0; i < count; i++ )); do
        msg="$(tg_calls --argjson i "$i" '.[$i].fields.text')"
        [[ "$msg" =~ [^[:space:]] ]] || fail "${name}: message $((i + 1)) is blank"
        units="$(utf16_units "$msg")"
        (( units <= 4096 )) || fail "${name}: message $((i + 1)) has ${units} units (> 4096)"
        if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit <= 4096 && limit >= 16 )); then
            (( units <= limit )) || fail "${name}: message $((i + 1)) has ${units} units (> ${limit})"
        fi
        [[ "$(tg_calls --argjson i "$i" '.[$i].fields | has("parse_mode")')" == "false" ]] \
            || fail "${name}: report text sent with parse_mode"
    done
    echo "$count"
}

joined_texts() {
    tg_calls '[.[].fields.text] | join("")'
}

# The original bug: an over-long first line produced an empty message, then
# one over the limit.
long_line="$(repeat x 10000)"
n="$(send_case "single long line" 3800 "$long_line")"
assert_eq "$n" "3" "single long line message count"
assert_eq "$(joined_texts)" "$long_line" "single long line content"

# Same after a short line, and with the default limit.
n="$(send_case "short then long" 3800 "header"$'\n'"$long_line")"
(( n == 4 )) || fail "short then long: expected 4 messages, got ${n}"
assert_eq "$(tg_calls '.[0].fields.text')" "header" "short line kept whole"

# Emoji outside the BMP count as two UTF-16 units each.
emoji="$(repeat '😀' 3000)"
n="$(send_case "emoji line" 4096 "$emoji")"
assert_eq "$n" "2" "emoji line message count"
assert_eq "$(joined_texts)" "$emoji" "emoji line content"

# Whitespace-only stretches never become messages.
spaced="first"$'\n\n'"$(repeat ' ' 5000)"$'\n\n'"$(repeat $'\t' 5000)"$'\n\n'"last"
send_case "whitespace stretches" 3800 "$spaced" >/dev/null
assert_eq "$(tg_calls '[.[].fields.text | select(test("first"))] | length')" "1" "first paragraph sent"
assert_eq "$(tg_calls '[.[].fields.text | select(test("last"))] | length')" "1" "last paragraph sent"

# Empty input sends nothing at all.
assert_eq "$(send_case "empty" 3800 "")" "0" "empty text"
assert_eq "$(send_case "blank" 3800 $'\n \n\t\n')" "0" "blank text"

# Normal lines are never cut: every message is made of whole input lines.
lines=""
for i in $(seq 1 400); do
    lines+="line ${i}: $(repeat '=' $(( i % 37 )))"$'\n'
done
send_case "many lines" 1000 "$lines" >/dev/null
while IFS= read -r line; do
    grep -qxF -- "$line" <<< "$lines" || fail "many lines: a line was cut: ${line}"
done < <(tg_calls '.[].fields.text')

# Out-of-range limits are clamped to Telegram's maximum.
send_case "huge limit" 999999 "$long_line" >/dev/null
send_case "bad limit" "abc" "$long_line" >/dev/null
assert_eq "$(TG_CHUNK_LIMIT=999999 tg_chunk_limit)" "4096" "clamp large limit"
assert_eq "$(TG_CHUNK_LIMIT=abc tg_chunk_limit)" "4096" "clamp invalid limit"
assert_eq "$(TG_CHUNK_LIMIT=3 tg_chunk_limit)" "16" "clamp tiny limit"

echo "tg_split_test: ok"
