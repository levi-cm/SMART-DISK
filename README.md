# SMART Watcher

Dockerized SMART disk monitoring with Telegram alerts. The container runs scheduled `smartctl` checks, sends configurable burst alerts, answers `/scan`, `/full` and `/heartbeat` Telegram commands with visual reports, and stores runtime state in `state/`.

## What It Monitors

The default `paranoid` policy preserves the original behavior: every detected finding alerts, including nonzero `smartctl` status, failed overall SMART health, meaningful error counters, SMART error-log entries, failed self-tests, NVMe critical warnings, NVMe media errors, low NVMe spare, high NVMe wear, and temperatures above the configured limit.

Findings carry severity instead of being described as certain drive failure:

- `advisory`: historical or cumulative evidence such as old error-log entries or CRC counters. Investigate trends and cabling; this is not proof of imminent failure.
- `degraded`: active margin concerns such as excessive temperature, reallocated sectors, low SSD life, or high NVMe wear.
- `critical`: active failure indicators such as failed health, pending or uncorrectable sectors, failed self-tests, NVMe media errors, low spare, or unreadable SMART data.

## Files

- `docker-compose.yml`: runtime container, explicit drive mappings, resource limits, and hardening.
- `Dockerfile`: builds a self-contained image with the scripts copied into `/scripts`.
- `scripts/`: watcher, Telegram poller, SMART parser, and locked JSON state helpers.
- `config/drives.conf`: private/local list of devices to scan.
- `config/users.conf`: private/local allowlist of Telegram chat IDs.
- `.env`: private/local Telegram token and host label.
- `state/`: private/local runtime state.
- `tests/`: fixture-based tests for parsing, alerts, reports and config, an offline container smoke test, and open-source readiness checks.

## Quick Start

Copy the safe examples:

```bash
cp .env.example .env
cp config/users.conf.example config/users.conf
cp config/drives.conf.example config/drives.conf
```

Edit `.env`:

```env
TELEGRAM_BOT_TOKEN=replace-with-your-real-token
HOST_NAME=smart-watcher
SMART_POLICY=paranoid
BURST_COUNT=10
BURST_DELAY=30
```

Edit `config/users.conf` and put one authorized Telegram chat ID per line. Only these chats can use `/scan`, `/full`, `/heartbeat`, and `/help`.

List disks on the host:

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL
```

Edit `config/drives.conf` to list the devices to scan:

```text
/dev/sda
/dev/sdb
```

Edit `docker-compose.yml` so every device in `config/drives.conf` is also present under `services.smart-watcher.devices`.

Start the watcher:

```bash
docker compose config --quiet
docker compose up -d --build
docker compose ps
docker compose logs -f smart-watcher
```

Run one manual check:

```bash
docker compose exec smart-watcher /scripts/smart_check.sh /dev/sda
```

## State Directory Permissions

The container writes lock files and JSON state under `/state`. If the container is unhealthy or logs `/state/.lock: Permission denied`, align the host bind mount with the container root user:

```bash
sudo chown root:root state state/.lock state/last_status.json 2>/dev/null || true
sudo chmod 755 state
sudo chmod 600 state/.lock state/last_status.json 2>/dev/null || true
docker compose up -d
```

For a fresh install, Docker may create missing state files on first start. Recheck with:

```bash
docker compose ps
docker compose logs --tail 100 smart-watcher
```

## Adding Drives

Add the drive in two places:

1. Add the device path to `config/drives.conf`.
2. Add the same host device to `docker-compose.yml` under `devices:`.

Example:

```yaml
devices:
  - /dev/sda:/dev/sda
  - /dev/sdb:/dev/sdb
  - /dev/sdc:/dev/sdc
```

Stable `/dev/disk/by-id/...` paths are better than `/dev/sdX` when your host supports them, because `/dev/sdX` names can move after reboot.

## Telegram Commands

- `/scan`: run a scan now. You get one acknowledgement, then one compact report.
- `/full`: the same report, plus a Markdown file with the evidence and the raw `smartctl -a` text for every drive.
- `/heartbeat`: enable, disable, or check the healthy heartbeat message.
- `/help`: show command help.

The watcher registers these commands with Telegram (`setMyCommands`) on start, so they appear in the chat's command menu. The menu and `/help` are built from the same list in `scripts/bot_poller.sh`. Unknown chat IDs are rejected.

Reports are plain Unicode text (no parse mode), so drive paths and host labels show exactly as configured. The report starts with an overview: the worst severity and the number of drives in each state. Then each drive gets a card with its verdict, temperature, power-on hours and, for NVMe, gauges for wear (percentage used) and available spare. A value the drive does not report shows as `—`, not 0. Wear above 100% means the drive is past its rated endurance:

```text
🔴 SMART scan · my-server
Worst: CRITICAL · 3 drives
🟢 1 good · 🟠 1 degraded · 🔴 1 critical
🕒 2026-01-01 00:00 UTC

🟢 /dev/sda — GOOD
   Fixture HDD 4000 · 4 TB
   🌡 34 °C · ⏱ 12,345 h (1.4 y)

🟠 /dev/nvme0n1 — DEGRADED
   Fixture NVMe 2TB · 2 TB
   🌡 41 °C · ⏱ 8,760 h (1 y)
   Wear  ▰▰▰▰▰▰▰▰▰▰ 117% used · past rated endurance
   Spare ▰▰▰▰▰▰▰▰▰▰ 100% (min 10%)
   • nvme_percentage_used=117>=80

🔴 /dev/sdc — CRITICAL
   Fixture HDD 2000 · 2 TB
   🌡 38 °C · ⏱ 43,800 h (5 y)
   • Offline_Uncorrectable(198)=1
   • Current_Pending_Sector(197)=2
   • Reported_Uncorrect(187)=4
   • +2 more, see /full

Send /full for raw smartctl output.
```

Each report reads every drive once, with `smartctl -a --json=o`, which returns the JSON and the original text together. The verdict, the card and the attached raw output therefore come from the same read. `/full` writes its attachment into a fresh temporary directory and deletes it after sending. Long reports are split at card boundaries to stay under Telegram's 4096-character limit.

## Configuration

These environment values can be set in `.env` or `docker-compose.yml`:

- `TELEGRAM_BOT_TOKEN`: required Telegram bot token.
- `HOST_NAME`: label used in Telegram messages.
- `SMART_POLICY`: `paranoid` by default; `balanced` keeps all warnings but reserves burst alerts for critical findings and sends one alert for new advisory/degraded findings.
- `SCAN_INTERVAL`: seconds between automatic scans, default `21600`.
- `BURST_COUNT`: number of messages in a burst alert, default `10`.
- `BURST_DELAY`: seconds between burst messages, default `30`.
- `REMINDER_INTERVAL`: seconds between repeated degraded-state reminders, default `86400`.
- `HEARTBEAT_EVERY`: send healthy heartbeat every N scans, default `4`; set `0` to disable scheduled heartbeats.
- `TEMP_LIMIT`: maximum accepted drive temperature in Celsius, default `50`.
- `SSD_LIFE_MIN`: minimum accepted ATA SSD life attribute value, default `90`.
- `TELEGRAM_API_BASE`: Bot API base URL, default `https://api.telegram.org`. Set it for a self-hosted Bot API server; the offline smoke test uses it to reach its mock. Every request carries the bot token, so only point it at a server you control.
- `TG_CHUNK_LIMIT`: maximum characters (UTF-16 code units) per report message, default `3800`, capped at Telegram's `4096`.

`paranoid` remains the explicit default and bursts on every new or changed non-OK finding. `balanced` sends a single alert for advisory/degraded transitions and still bursts on critical findings. Both policies retain reminders, suppress unchanged alerts inside `REMINDER_INTERVAL`, send recovery messages, and withhold healthy heartbeats whenever any drive is non-OK. Set `BURST_COUNT=10` and `BURST_DELAY=30` for the original burst behavior; other positive values remain supported.

## Publishing Safely

Private files are ignored by both Git and Docker build context:

- `.env`
- `config/users.conf`
- `state/`

Before publishing, run:

```bash
bash tests/open_source_readiness_test.sh
git status --ignored --short
```

Do not upload a zip of the raw working directory unless you manually remove `.env`, `config/users.conf`, and `state/` first. If a Telegram token is ever exposed, revoke it in BotFather and create a new token.

## Development

Run checks (the same gates as CI):

```bash
for t in tests/*_test.sh; do bash "$t" || break; done
shellcheck scripts/*.sh tests/*.sh tests/smoke/*.sh
for f in scripts/*.sh tests/*.sh tests/smoke/*.sh; do bash -n "$f"; done
docker compose config --quiet
docker compose build
```

Run `bash -n` once per file: `bash -n a.sh b.sh` checks only `a.sh` and passes `b.sh` to it as an argument.

`tests/container_smoke_test.sh` needs Docker but no network, token, chat or disk. It builds the image and runs it with `--network none` and the compose hardening flags. A mock Bot API (busybox `nc`, already in the image) listens on the container's loopback, `TELEGRAM_API_BASE` points at it, and a fake `smartctl` serves fixture drives. The test then checks the messages and the `/full` upload the mock received. Set `SMOKE_ARTIFACTS=<dir>` to keep the captured requests and the container log.

Because scripts are copied into the image, rebuild after editing files under `scripts/`:

```bash
docker compose up -d --build
```

For live SMART checks:

```bash
for drive in $(grep -vE '^\s*(#|$)' config/drives.conf); do
    docker compose exec smart-watcher /scripts/smart_check.sh "$drive"
done
```
