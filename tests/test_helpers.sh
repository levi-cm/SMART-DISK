#!/usr/bin/env bash
# test_helpers.sh — shared helpers for tests/*_test.sh. Sourced, not run.
# shellcheck disable=SC2034 # Variables set here are read by the sourcing test.
# shellcheck disable=SC2317 # The tg_api recorder is called by the code under test.

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPORT_FIXTURES="${ROOT_DIR}/tests/fixtures/reports"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local actual="$1" expected="$2" what="$3"
    [[ "$actual" == "$expected" ]] || fail "${what}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local haystack="$1" needle="$2" what="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "${what}: missing '${needle}' in:
${haystack}"
}

assert_not_contains() {
    local haystack="$1" needle="$2" what="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "${what}: unexpected '${needle}' in:
${haystack}"
}

# utf16_units <text>: length in UTF-16 code units, the unit Telegram counts.
utf16_units() {
    printf '%s' "$1" | jq -n --rawfile t /dev/stdin '[$t | explode[] | if . > 65535 then 2 else 1 end] | add // 0'
}

# make_fake_smartctl <dir>
# Writes <dir>/smartctl. It looks up the drive (its last argument) in
# <dir>/drive_map.tsv ("drive<TAB>fixture" lines) and prints that fixture.
# A fixture may be "a.json,b.json": call N prints the Nth file (the last one
# repeats), to catch code that reads a drive more than once. Each call is
# logged as "drive<TAB>arguments" to $FAKE_SMARTCTL_LOG, else <dir>/reads.log.
make_fake_smartctl() {
    local dir="$1"
    : > "${dir}/drive_map.tsv"
    : > "${dir}/reads.log"
    cat > "${dir}/smartctl" <<'SH'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
log="${FAKE_SMARTCTL_LOG:-${dir}/reads.log}"
drive="${*: -1}"
printf '%s\t%s\n' "$drive" "$*" >> "$log"
calls="$(awk -F '\t' -v d="$drive" '$1 == d' "$log" | wc -l)"
while IFS=$'\t' read -r path fixtures; do
    [[ "$path" == "$drive" ]] || continue
    IFS=',' read -ra list <<< "$fixtures"
    idx=$(( calls <= ${#list[@]} ? calls - 1 : ${#list[@]} - 1 ))
    cat "${list[$idx]}"
    exit 0
done < "${dir}/drive_map.tsv"
exit 2
SH
    chmod +x "${dir}/smartctl"
}

# map_drive <dir> <drive> <fixture[,fixture...]>
map_drive() {
    printf '%s\t%s\n' "$2" "$3" >> "${1}/drive_map.tsv"
}

# reads_of <reads.log> <drive> [argument pattern]
# How many times the fake smartctl read <drive> (with matching arguments).
reads_of() {
    awk -F '\t' -v d="$2" -v p="${3:-}" '$1 == d && index($2, p)' "$1" | wc -l | tr -d ' '
}

# record_tg_api <dir>
# Replaces tg_api (from scripts/telegram.sh) with a recorder. Every call is
# appended to <dir>/calls.jsonl as {method, fields}. An uploaded document is
# copied to <dir>/doc-N.md at send time, and its temp path is kept in
# fields.document_path so a test can check it was deleted afterwards.
record_tg_api() {
    TG_RECORD_DIR="$1"
    : > "${TG_RECORD_DIR}/calls.jsonl"
    tg_api() {
        local method="$1" spec doc_path="" n
        shift 2
        local -a pairs=()
        while (( $# > 0 )); do
            case "$1" in
                --data-urlencode|--form-string)
                    pairs+=("$2")
                    shift 2
                    ;;
                -F)
                    spec="${2#*=@}"
                    doc_path="${spec%%;*}"
                    pairs+=("document_path=${doc_path}")
                    pairs+=("document_name=$(sed -n 's/.*;filename=\([^;]*\).*/\1/p' <<< "$2")")
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        n="$(wc -l < "${TG_RECORD_DIR}/calls.jsonl" | tr -d ' ')"
        if [[ -n "$doc_path" ]]; then
            cp "$doc_path" "${TG_RECORD_DIR}/doc-${n}.md"
            pairs+=("document_copy=${TG_RECORD_DIR}/doc-${n}.md")
        fi
        { (( ${#pairs[@]} > 0 )) && printf '%s\037' "${pairs[@]}"; } | jq -n -c --rawfile raw /dev/stdin --arg m "$method" '
            {method: $m, fields: ($raw | split("\u001f") | map(select(length > 0) | index("=") as $i
                | {key: .[:$i], value: .[$i + 1:]}) | from_entries)}' >> "${TG_RECORD_DIR}/calls.jsonl"
        echo '{"ok":true,"result":true}'
    }
}

# tg_calls [jq options...] <filter>
# Runs <filter> over the recorded calls as one array; strings print raw.
tg_calls() {
    (( $# > 0 )) || set -- .
    jq -s -r "$@" "${TG_RECORD_DIR}/calls.jsonl"
}
