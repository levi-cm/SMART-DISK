#!/usr/bin/env bash
# smart_check.sh <drive> [snapshot.json]
# Prints: "OK <drive>" or "WARN|FAIL <drive> severity=<level>|<reason>"
# Exits 0 always (parent reads stdout).
# With a snapshot (saved `smartctl -a --json` output) the drive is not read
# again, so a report's verdict and its raw output come from the same read.

set -u

DRIVE="${1:-}"
SNAPSHOT="${2:-}"
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
TEMP_LIMIT="${TEMP_LIMIT:-50}"
SSD_LIFE_MIN="${SSD_LIFE_MIN:-90}"
SMART_POLICY="${SMART_POLICY:-paranoid}"

emit_finding() {
    local severity="$1" reason="$2" status="FAIL"
    if [[ "$SMART_POLICY" == "balanced" && "$severity" == "advisory" ]]; then
        status="WARN"
    fi
    echo "${status} ${DRIVE:-unknown} severity=${severity}|${reason}"
    exit 0
}

if [[ -z "$DRIVE" ]]; then
    emit_finding critical "no_drive_arg"
fi

if [[ "$SMART_POLICY" != "paranoid" && "$SMART_POLICY" != "balanced" ]]; then
    emit_finding critical "invalid_smart_policy=${SMART_POLICY}"
fi

# Paranoid SMART attribute IDs whose raw_value > 0 indicates trouble.
# These are error/failure counters, not normal lifetime counters.
# 1   Raw_Read_Error_Rate
# 5   Reallocated_Sector_Ct
# 7   Seek_Error_Rate
# 10  Spin_Retry_Count
# 11  Calibration_Retry_Count
# 160 Uncorrectable_Error_Cnt
# 171 Program_Fail_Count
# 172 Erase_Fail_Count
# 181 Program_Fail_Cnt_Total
# 182 Erase_Fail_Count_Total
# 183 Runtime_Bad_Block
# 184 End-to-End_Error
# 187 Reported_Uncorrect
# 188 Command_Timeout
# 196 Reallocated_Event_Count
# 197 Current_Pending_Sector
# 198 Offline_Uncorrectable
# 199 UDMA_CRC_Error_Count
# 200 Multi_Zone_Error_Rate

if [[ -n "$SNAPSHOT" ]]; then
    { JSON="$(< "$SNAPSHOT")"; } 2>/dev/null || JSON=""
else
    JSON="$("$SMARTCTL_BIN" -a -j "$DRIVE" 2>/dev/null || true)"
fi

if [[ -z "$JSON" ]]; then
    emit_finding critical "smartctl_no_output"
fi

# Single jq pass: extract everything we need with a non-whitespace separator.
DATA="$(jq -r '
    def n: tonumber? // 0;
    def advisory_attr_ids: [1,7,10,11,171,172,181,182,183,188,196,199,200];
    def degraded_attr_ids: [5];
    def critical_attr_ids: [160,184,187,197,198];
    def life_attr_ids: [169,177,231,232,233];
    def raw_n: (.raw.value // 0 | n);
    def error_name: ((.name // "") | test("Error|Uncorrect|Realloc|Pending|Timeout|Retry|Bad_Block|CRC|End-to-End|Multi_Zone|Fail"; "i"));
    def attr_label: "\(.name // "attr")(\(.id))=\(.raw.value // 0)";

    [
      (.smartctl.exit_status // 0 | tostring),
      (if .smart_status then "1" else "0" end),
      (.smart_status.passed // false | tostring),
      (.temperature.current
        // (.ata_smart_attributes.table[]? | select(.id == 194) | .raw.value
              # The raw value packs min/max above the low byte (current).
              | if type == "number" and . > 255 then . % 256 else . end)
        // "" | tostring),
      ((.ata_smart_attributes.table // [])
        | map(select(.id as $i | advisory_attr_ids | index($i)))
        | map(select(error_name))
        | map(select(raw_n > 0))
        | map(attr_label)
        | join("|")),
      ((.ata_smart_attributes.table // [])
        | map(select(.id as $i | degraded_attr_ids | index($i)))
        | map(select(error_name))
        | map(select(raw_n > 0))
        | map(attr_label)
        | join("|")),
      ((.ata_smart_attributes.table // [])
        | map(select(.id as $i | critical_attr_ids | index($i)))
        | map(select(error_name))
        | map(select(raw_n > 0))
        | map(attr_label)
        | join("|")),
      ((.ata_smart_attributes.table // [])
        | map(select((.thresh // 0 | n) > 0))
        | map(select(((.value // 100 | n) <= (.thresh // 0 | n)) or ((.worst // 100 | n) <= (.thresh // 0 | n))))
        | map("threshold:\(.name // "attr")(\(.id)) value=\(.value // "?") worst=\(.worst // "?") thresh=\(.thresh // "?")")
        | join("|")),
      ((.ata_smart_attributes.table // [])
        | map(select(.id as $i | life_attr_ids | index($i)))
        | map(select((.value // 100 | n) < ($life_min | n)))
        | map("life:\(.name // "attr")(\(.id)) value=\(.value // "?")<\($life_min)")
        | join("|")),
      (.ata_smart_error_log.summary.count // 0 | tostring),
      ((.ata_smart_self_test_log.standard.table // [])
        | map(select(.status.passed == false or (((.status.string // "Completed without error") | test("Completed without error"; "i")) | not)))
        | length | tostring),
      (.nvme_smart_health_information_log.critical_warning // "" | tostring),
      (.nvme_smart_health_information_log.media_errors // "" | tostring),
      (.nvme_smart_health_information_log.num_err_log_entries // "" | tostring),
      (.nvme_smart_health_information_log.available_spare // "" | tostring),
      (.nvme_smart_health_information_log.available_spare_threshold // "" | tostring),
      (.nvme_smart_health_information_log.percentage_used // "" | tostring)
    ] | join("\u001f")
' --argjson life_min "$SSD_LIFE_MIN" <<< "$JSON" 2>/dev/null)"

if [[ -z "$DATA" ]]; then
    emit_finding critical "jq_parse_failed"
fi

IFS=$'\037' read -r EXIT_STATUS HAS_STATUS PASSED TEMP ADVISORY_ATTRS DEGRADED_ATTRS CRITICAL_ATTRS THRESH_ATTRS LIFE_ATTRS ATA_ERR_COUNT SELF_TEST_FAILS NVME_CRIT_WARN NVME_MEDIA_ERRS NVME_ERR_LOGS NVME_SPARE NVME_SPARE_THRESH NVME_USED <<< "$DATA"

ADVISORY_REASONS=()
DEGRADED_REASONS=()
CRITICAL_REASONS=()

if [[ "$EXIT_STATUS" =~ ^[0-9]+$ ]] && (( EXIT_STATUS != 0 )); then
    ADVISORY_REASONS+=("smartctl_exit_status=${EXIT_STATUS}")
fi

if [[ "$HAS_STATUS" != "1" ]]; then
    CRITICAL_REASONS+=("smartctl_unreadable")
fi

if [[ "$PASSED" != "true" ]]; then
    CRITICAL_REASONS+=("overall_health_FAILED")
fi

add_pipe_reasons() {
    local severity="$1" items="$2" item
    local -a item_list
    [[ -z "$items" ]] && return 0
    IFS='|' read -ra item_list <<< "$items"
    for item in "${item_list[@]}"; do
        [[ -z "$item" ]] && continue
        case "$severity" in
            advisory) ADVISORY_REASONS+=("$item") ;;
            degraded) DEGRADED_REASONS+=("$item") ;;
            critical) CRITICAL_REASONS+=("$item") ;;
        esac
    done
}

add_pipe_reasons advisory "$ADVISORY_ATTRS"
add_pipe_reasons degraded "$DEGRADED_ATTRS"
add_pipe_reasons critical "$CRITICAL_ATTRS"
add_pipe_reasons critical "$THRESH_ATTRS"
add_pipe_reasons degraded "$LIFE_ATTRS"

if [[ "$ATA_ERR_COUNT" =~ ^[0-9]+$ ]] && (( ATA_ERR_COUNT > 0 )); then
    ADVISORY_REASONS+=("smart_error_log_count=${ATA_ERR_COUNT}")
fi

if [[ "$SELF_TEST_FAILS" =~ ^[0-9]+$ ]] && (( SELF_TEST_FAILS > 0 )); then
    CRITICAL_REASONS+=("self_test_failures=${SELF_TEST_FAILS}")
fi

if [[ "$NVME_CRIT_WARN" =~ ^[0-9]+$ ]] && (( NVME_CRIT_WARN > 0 )); then
    CRITICAL_REASONS+=("nvme_critical_warning=${NVME_CRIT_WARN}")
fi

if [[ "$NVME_MEDIA_ERRS" =~ ^[0-9]+$ ]] && (( NVME_MEDIA_ERRS > 0 )); then
    CRITICAL_REASONS+=("nvme_media_errors=${NVME_MEDIA_ERRS}")
fi

if [[ "$NVME_ERR_LOGS" =~ ^[0-9]+$ ]] && (( NVME_ERR_LOGS > 0 )); then
    ADVISORY_REASONS+=("nvme_error_log_entries=${NVME_ERR_LOGS}")
fi

if [[ "$NVME_SPARE" =~ ^[0-9]+$ && "$NVME_SPARE_THRESH" =~ ^[0-9]+$ ]] && (( NVME_SPARE <= NVME_SPARE_THRESH )); then
    CRITICAL_REASONS+=("nvme_available_spare=${NVME_SPARE}<=${NVME_SPARE_THRESH}")
fi

if [[ "$NVME_USED" =~ ^[0-9]+$ ]] && (( NVME_USED >= 80 )); then
    DEGRADED_REASONS+=("nvme_percentage_used=${NVME_USED}>=80")
fi

if [[ -n "$TEMP" && "$TEMP" =~ ^[0-9]+$ ]] && (( TEMP > TEMP_LIMIT )); then
    DEGRADED_REASONS+=("temp=${TEMP}C>${TEMP_LIMIT}C")
fi

# Keep this order: report_record.jq reverses it to list critical evidence first.
ALL_REASONS=("${ADVISORY_REASONS[@]}" "${DEGRADED_REASONS[@]}" "${CRITICAL_REASONS[@]}")
if (( ${#ALL_REASONS[@]} > 0 )); then
    severity="advisory"
    (( ${#DEGRADED_REASONS[@]} > 0 )) && severity="degraded"
    (( ${#CRITICAL_REASONS[@]} > 0 )) && severity="critical"
    joined="$(IFS='|'; echo "${ALL_REASONS[*]}")"
    emit_finding "$severity" "$joined"
fi

echo "OK $DRIVE"
exit 0
