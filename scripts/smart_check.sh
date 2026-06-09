#!/usr/bin/env bash
# smart_check.sh <drive>
# Prints: "OK <drive>" or "FAIL <drive> <reason>"
# Exits 0 always (parent reads stdout).

set -u

DRIVE="${1:-}"
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
TEMP_LIMIT="${TEMP_LIMIT:-50}"
SSD_LIFE_MIN="${SSD_LIFE_MIN:-90}"

if [[ -z "$DRIVE" ]]; then
    echo "FAIL unknown no_drive_arg"
    exit 0
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

JSON="$("$SMARTCTL_BIN" -a -j "$DRIVE" 2>/dev/null || true)"

if [[ -z "$JSON" ]]; then
    echo "FAIL $DRIVE smartctl_no_output"
    exit 0
fi

# Single jq pass: extract everything we need with a non-whitespace separator.
DATA="$(jq -r '
    def n: tonumber? // 0;
    def error_attr_ids: [1,5,7,10,11,160,171,172,181,182,183,184,187,188,196,197,198,199,200];
    def life_attr_ids: [169,177,231,232,233];
    def raw_n: (.raw.value // 0 | n);
    def error_name: ((.name // "") | test("Error|Uncorrect|Realloc|Pending|Timeout|Retry|Bad_Block|CRC|End-to-End|Multi_Zone|Fail"; "i"));
    def attr_label: "\(.name // "attr")(\(.id))=\(.raw.value // 0)";

    [
      (.smartctl.exit_status // 0 | tostring),
      (if .smart_status then "1" else "0" end),
      (.smart_status.passed // false | tostring),
      (.temperature.current
        // (.ata_smart_attributes.table[]? | select(.id == 194) | .raw.value)
        // "" | tostring),
      ((.ata_smart_attributes.table // [])
        | map(select(.id as $i | error_attr_ids | index($i)))
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
        | map(select((.status.passed // true) == false or (((.status.string // "Completed without error") | test("Completed without error"; "i")) | not)))
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
    echo "FAIL $DRIVE jq_parse_failed"
    exit 0
fi

IFS=$'\037' read -r EXIT_STATUS HAS_STATUS PASSED TEMP CRIT_ATTRS THRESH_ATTRS LIFE_ATTRS ATA_ERR_COUNT SELF_TEST_FAILS NVME_CRIT_WARN NVME_MEDIA_ERRS NVME_ERR_LOGS NVME_SPARE NVME_SPARE_THRESH NVME_USED <<< "$DATA"

REASONS=()

if [[ "$EXIT_STATUS" =~ ^[0-9]+$ ]] && (( EXIT_STATUS != 0 )); then
    REASONS+=("smartctl_exit_status=${EXIT_STATUS}")
fi

if [[ "$HAS_STATUS" != "1" ]]; then
    REASONS+=("smartctl_unreadable")
fi

if [[ "$PASSED" != "true" ]]; then
    REASONS+=("overall_health_FAILED")
fi

add_pipe_reasons() {
    local items="$1"
    local item
    [[ -z "$items" ]] && return 0
    IFS='|' read -ra item_list <<< "$items"
    for item in "${item_list[@]}"; do
        [[ -n "$item" ]] && REASONS+=("$item")
    done
}

add_pipe_reasons "$CRIT_ATTRS"
add_pipe_reasons "$THRESH_ATTRS"
add_pipe_reasons "$LIFE_ATTRS"

if [[ "$ATA_ERR_COUNT" =~ ^[0-9]+$ ]] && (( ATA_ERR_COUNT > 0 )); then
    REASONS+=("smart_error_log_count=${ATA_ERR_COUNT}")
fi

if [[ "$SELF_TEST_FAILS" =~ ^[0-9]+$ ]] && (( SELF_TEST_FAILS > 0 )); then
    REASONS+=("self_test_failures=${SELF_TEST_FAILS}")
fi

if [[ "$NVME_CRIT_WARN" =~ ^[0-9]+$ ]] && (( NVME_CRIT_WARN > 0 )); then
    REASONS+=("nvme_critical_warning=${NVME_CRIT_WARN}")
fi

if [[ "$NVME_MEDIA_ERRS" =~ ^[0-9]+$ ]] && (( NVME_MEDIA_ERRS > 0 )); then
    REASONS+=("nvme_media_errors=${NVME_MEDIA_ERRS}")
fi

if [[ "$NVME_ERR_LOGS" =~ ^[0-9]+$ ]] && (( NVME_ERR_LOGS > 0 )); then
    REASONS+=("nvme_error_log_entries=${NVME_ERR_LOGS}")
fi

if [[ "$NVME_SPARE" =~ ^[0-9]+$ && "$NVME_SPARE_THRESH" =~ ^[0-9]+$ ]] && (( NVME_SPARE <= NVME_SPARE_THRESH )); then
    REASONS+=("nvme_available_spare=${NVME_SPARE}<=${NVME_SPARE_THRESH}")
fi

if [[ "$NVME_USED" =~ ^[0-9]+$ ]] && (( NVME_USED >= 80 )); then
    REASONS+=("nvme_percentage_used=${NVME_USED}>=80")
fi

if [[ -n "$TEMP" && "$TEMP" =~ ^[0-9]+$ ]] && (( TEMP > TEMP_LIMIT )); then
    REASONS+=("temp=${TEMP}C>${TEMP_LIMIT}C")
fi

if (( ${#REASONS[@]} > 0 )); then
    joined="$(IFS='|'; echo "${REASONS[*]}")"
    echo "FAIL $DRIVE $joined"
    exit 0
fi

echo "OK $DRIVE"
exit 0
