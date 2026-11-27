# report_render.jq: plain-text SMART report for Telegram (jq -r -s).
# Input: the drive records written by report_lib.sh, one JSON object per line.
# Named args: host, generated (time label), mode ("scan" or "full").
# Unicode text only (emoji verdicts and ▰▱ gauges), so it renders in any
# client without parse_mode. A missing value prints as "—", never as 0.

def dash: "—";
def isnum: type == "number";
def severities: ["ok", "advisory", "degraded", "critical"];
def sev_rank: {"ok": 0, "advisory": 1, "degraded": 2, "critical": 3}[.] // 3;
def sev_icon: {"ok": "🟢", "advisory": "🟡", "degraded": "🟠", "critical": "🔴"}[.] // "🔴";
def sev_label: {"ok": "GOOD", "advisory": "ADVISORY", "degraded": "DEGRADED", "critical": "CRITICAL"}[.] // "CRITICAL";
def sev_noun: {"ok": "good", "advisory": "advisory", "degraded": "degraded", "critical": "critical"}[.] // "critical";

def commas:
  if . < 1000 then tostring
  else ((. / 1000 | floor) | commas) + "," + ((. % 1000 | tostring) as $r | ("00" + $r)[-3:])
  end;

def one_decimal: if . >= 10 then (round | tostring) else ((. * 10 | round) / 10 | tostring) end;

def temp: if isnum then "\(.) °C" else dash end;

def hours:
  if isnum then
    "\(floor | commas) h" + (if . >= 8760 then " (\(. / 8760 | one_decimal) y)" else "" end)
  else dash end;

def size:
  if isnum and . >= 1e12 then "\(. / 1e12 | one_decimal) TB"
  elif isnum and . >= 1e9 then "\(. / 1e9 | one_decimal) GB"
  elif isnum and . > 0 then "\(. / 1e6 | one_decimal) MB"
  else null end;

# Ten-cell gauge. Only exactly 0 is empty and only 100 or more is full, so a
# small but non-zero value never looks like nothing and 96% never looks full.
def cells:
  ([[., 0] | max, 100] | min) as $p
  | ($p / 10 | round) as $c
  | if $p > 0 and $c == 0 then 1 elif $p < 100 and $c == 10 then 9 else $c end;

def bar: cells as $c | ([range(0; $c)] | map("▰") | join("")) + ([range($c; 10)] | map("▱") | join(""));

def wear_line:
  if isnum then
    "Wear  \(bar) \(.)% used" + (if . > 100 then " · past rated endurance" else "" end)
  else "Wear  \(dash)" end;

def spare_line($min):
  if isnum then
    "Spare \(bar) \(.)%" + (if ($min | isnum) then " (min \($min)%)" else "" end)
  else "Spare \(dash)" end;

def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

# $max_evidence: how many evidence lines to show, or null for all of them.
def card($max_evidence):
  . as $r
  | ($r.metrics // {}) as $m
  | ($r.reasons // []) as $ev
  | ["\($r.severity | sev_icon) \($r.drive) — \($r.severity | sev_label)"]
    + ([$m.model, ($m.capacity_bytes | size)] | map(select(. != null)) | if length > 0 then ["   " + join(" · ")] else [] end)
    + ["   🌡 \($m.temp_c | temp) · ⏱ \($m.power_on_hours | hours)"]
    + (if $m.is_nvme == true then
         ["   " + ($m.nvme_used_pct | wear_line), "   " + ($m.nvme_spare_pct | spare_line($m.nvme_spare_thresh_pct))]
       else [] end)
    + (if $max_evidence != null and ($ev | length) > $max_evidence then
         ($ev[:$max_evidence] | map("   • " + .)) + ["   • +\(($ev | length) - $max_evidence) more, see /full"]
       else $ev | map("   • " + .) end)
  | join("\n");

($ARGS.named.host // "unknown-host") as $host
| ($ARGS.named.generated // "") as $generated
| ($ARGS.named.mode // "scan") as $mode
| (if $mode == "full" then "SMART full report" else "SMART scan" end) as $title
| . as $records
| if length == 0 then
    [ "⚪ \($title) · \($host)",
      "No drives configured: nothing was checked.",
      "Add device paths to config/drives.conf (and map them in docker-compose.yml).",
      "🕒 \($generated)" ] | join("\n")
  else
    (map(.severity | sev_rank) | max) as $worst_rank
    | severities[$worst_rank] as $worst
    | (severities | map(. as $s | ($records | map(select(.severity == $s)) | length) as $n
        | select($n > 0) | "\($s | sev_icon) \($n) \($s | sev_noun)") | join(" · ")) as $counts
    | ([ "\($worst | sev_icon) \($title) · \($host)",
         "Worst: \($worst | sev_label) · \(plural(length; "drive"))",
         $counts,
         "🕒 \($generated)" ] | join("\n"))
      + "\n\n"
      + (map(card(if $mode == "full" then null else 3 end)) | join("\n\n"))
      + "\n\n"
      + (if $mode == "full" then "📎 Raw smartctl output and evidence: attached file."
         else "Send /full for raw smartctl output." end)
  end
