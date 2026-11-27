#!/usr/bin/env bash
# shellcheck disable=SC2016 # Backticks are literal Markdown in the attachment.
# report_lib.sh — /scan and /full reports from one snapshot per drive.
# Each drive is read once with `smartctl -a --json=o`, which returns the JSON
# and the original text together. The verdict, the card and the attached raw
# output all come from that one read, so they cannot disagree.
# Needs smart_result_lib.sh plus SCRIPTS_DIR, SMARTCTL_BIN, SMART_CHECK_BIN
# and HOST_NAME from the caller.

# report_collect <workdir> [drive...]
# Saves <workdir>/snapshot-N.json per drive and appends one JSON record per
# drive to <workdir>/records.jsonl.
report_collect() {
    local workdir="$1"
    shift
    local drive snap verdict severity reason i=0
    local -a record_args
    : > "${workdir}/records.jsonl"
    for drive in "$@"; do
        i=$((i + 1))
        snap="${workdir}/snapshot-${i}.json"
        "$SMARTCTL_BIN" -a --json=o "$drive" < /dev/null > "$snap" 2>/dev/null || true
        verdict="$("$SMART_CHECK_BIN" "$drive" "$snap" < /dev/null)"
        smart_parse_result "$verdict"
        severity="$SMART_RESULT_SEVERITY"
        reason="$SMART_RESULT_REASON"
        case "$severity" in
            ok|advisory|degraded|critical) ;;
            *) severity="critical" ;;
        esac
        if [[ "$SMART_RESULT_STATUS" != "OK" && "$severity" == "ok" ]]; then
            severity="critical"
        fi
        if [[ -z "$verdict" ]]; then
            severity="critical"
            reason="smart_check_no_verdict"
        fi
        record_args=(
            --arg drive "$drive"
            --arg status "$SMART_RESULT_STATUS"
            --arg severity "$severity"
            --arg reason "$reason"
            --arg snapshot "$snap"
        )
        # If the snapshot file is unreadable (say /tmp is full), keep the
        # drive and its verdict; only the card metrics are lost.
        jq -n -c "${record_args[@]}" --rawfile raw "$snap" \
            -f "${SCRIPTS_DIR}/report_record.jq" >> "${workdir}/records.jsonl" 2>/dev/null \
            || jq -n -c "${record_args[@]}" --arg raw "" \
                -f "${SCRIPTS_DIR}/report_record.jq" >> "${workdir}/records.jsonl"
    done
}

# report_render <scan|full> <records.jsonl> [generated_label]
report_render() {
    local mode="$1" records="$2" generated="${3:-}"
    [[ -z "$generated" ]] && generated="$(date -u '+%Y-%m-%d %H:%M UTC')"
    jq -r -s \
        --arg mode "$mode" \
        --arg host "$HOST_NAME" \
        --arg generated "$generated" \
        -f "${SCRIPTS_DIR}/report_render.jq" "$records"
}

# report_worst <records.jsonl>: highest severity, or "none" with no drives.
report_worst() {
    jq -r -s '
        if length == 0 then "none"
        else (map({"ok": 0, "advisory": 1, "degraded": 2, "critical": 3}[.severity] // 3) | max) as $r
            | ["ok", "advisory", "degraded", "critical"][$r]
        end' "$1"
}

# report_raw_text <snapshot>
# The original smartctl text from the snapshot; if it has none, the snapshot
# exactly as read.
report_raw_text() {
    local snap="$1"
    if [[ ! -s "$snap" ]]; then
        echo "(smartctl produced no output)"
        return
    fi
    if ! jq -r '.smartctl.output | if type == "array" then .[] else error("no text output") end' "$snap" 2>/dev/null; then
        echo "(no original smartctl text in this snapshot; showing it as read)"
        cat -- "$snap"
    fi
}

# report_fence <text>: a code fence longer than any backtick run in <text>.
report_fence() {
    local fence='```'
    while [[ "$1" == *"$fence"* ]]; do
        fence+='`'
    done
    printf '%s' "$fence"
}

# report_write_markdown <records.jsonl> <out.md> <cards_text>
# The /full attachment: the same cards, then per drive the evidence and the
# raw smartctl text from the snapshot behind the verdict.
report_write_markdown() {
    local records="$1" out="$2" cards="$3"
    local drive severity snapshot reasons raw fence
    {
        printf '# SMART full report\n\n'
        fence="$(report_fence "$cards")"
        printf '%stext\n%s\n%s\n' "$fence" "$cards" "$fence"
    } > "$out"

    while IFS=$'\037' read -r drive severity snapshot reasons; do
        raw="$(report_raw_text "$snapshot")"
        fence="$(report_fence "$raw")"
        {
            printf '\n## %s `%s` — %s\n\n' "$(smart_severity_icon "$severity")" "$drive" "$(smart_severity_label "$severity")"
            if [[ -n "$reasons" ]]; then
                printf 'Evidence:\n\n'
                printf '%s\n' "$reasons" | tr '\036' '\n' | sed 's/.*/- `&`/'
            else
                printf 'Evidence: none, all checks passed.\n'
            fi
            printf '\nRaw smartctl output (`smartctl -a`, same read as the verdict):\n\n'
            printf '%stext\n%s\n%s\n' "$fence" "$raw" "$fence"
        } >> "$out"
    done < <(jq -r '[.drive, .severity, .snapshot, (.reasons | join("\u001e"))] | join("\u001f")' "$records")
}
