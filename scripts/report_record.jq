# report_record.jq: one drive record for report_render.jq (jq -n -c).
# Named args: drive, status, severity, reason, snapshot, and raw (the
# snapshot file's text, via --rawfile). Card fields come from the same
# `smartctl -a --json=o` snapshot that produced the verdict. A value that is
# missing stays null, so the renderer prints "—" rather than a made-up 0.

def num:
  if type == "number" then .
  elif type == "string" then (tonumber? // null)
  else null end;

def ata_raw($id): first(.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value) // null;

# ATA attribute 194 packs min/max into its raw value; the low byte is current.
def ata_temp: ata_raw(194) | num | if . == null then null elif . > 255 then . % 256 else . end;

def metrics:
  if type != "object" then {}
  else
    (.nvme_smart_health_information_log // null) as $nvme
    | {
        model: ((.model_name // .model_family // null) | if type == "string" and length > 0 then . else null end),
        capacity_bytes: ((.user_capacity.bytes // .nvme_total_capacity // null) | num),
        is_nvme: (((.device.type // "") == "nvme") or ($nvme != null)),
        temp_c: ((.temperature.current // null | num) // ata_temp),
        power_on_hours: ((.power_on_time.hours // null | num) // ($nvme.power_on_hours? // null | num) // (ata_raw(9) | num)),
        nvme_used_pct: ($nvme.percentage_used? // null | num),
        nvme_spare_pct: ($nvme.available_spare? // null | num),
        nvme_spare_thresh_pct: ($nvme.available_spare_threshold? // null | num)
      }
  end;

($ARGS.named.raw // "" | try fromjson catch null) as $snapshot
| {
    drive: $ARGS.named.drive,
    status: $ARGS.named.status,
    severity: $ARGS.named.severity,
    # smart_check.sh lists advisory, then degraded, then critical evidence;
    # reverse it so the most severe items lead and survive truncation.
    reasons: ($ARGS.named.reason // "" | if . == "" or . == "-" then [] else split("|") | reverse end),
    snapshot: $ARGS.named.snapshot,
    metrics: ($snapshot | metrics)
  }
