# SMART Watcher

Dockerized SMART disk monitoring with Telegram alerts. The container runs scheduled `smartctl` checks, sends burst alerts on failure, supports `/scan` and `/heartbeat` Telegram commands, and stores runtime state in `state/`.

## What It Monitors

The checker is intentionally paranoid. It alerts on nonzero `smartctl` status, failed overall SMART health, meaningful error counters, SMART error-log entries, failed self-tests, NVMe critical warnings, NVMe media errors, low NVMe spare, high NVMe wear, and temperatures above the configured limit.

## Files

- `docker-compose.yml`: runtime container, explicit drive mappings, resource limits, and hardening.
- `Dockerfile`: builds a self-contained image with the scripts copied into `/scripts`.
- `scripts/`: watcher, Telegram poller, SMART parser, and locked JSON state helpers.
- `config/drives.conf`: private/local list of devices to scan.
- `config/users.conf`: private/local allowlist of Telegram chat IDs.
- `.env`: private/local Telegram token and host label.
- `state/`: private/local runtime state.
- `tests/`: parser and open-source readiness checks.

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
```

Edit `config/users.conf` and put one authorized Telegram chat ID per line. Only these chats can use `/scan`, `/heartbeat`, and `/help`.

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

- `/scan`: run a scan now and return full SMART output.
- `/heartbeat`: enable, disable, or check the healthy heartbeat message.
- `/help`: show command help.

Unknown chat IDs are rejected.

## Configuration

These environment values can be set in `.env` or `docker-compose.yml`:

- `TELEGRAM_BOT_TOKEN`: required Telegram bot token.
- `HOST_NAME`: label used in Telegram messages.
- `SCAN_INTERVAL`: seconds between automatic scans, default `21600`.
- `BURST_COUNT`: number of first-failure alert messages, default `10`.
- `BURST_DELAY`: seconds between burst messages, default `30`.
- `REMINDER_INTERVAL`: seconds between repeated degraded-state reminders, default `86400`.
- `HEARTBEAT_EVERY`: send healthy heartbeat every N scans, default `4`; set `0` to disable scheduled heartbeats.
- `TEMP_LIMIT`: maximum accepted drive temperature in Celsius, default `50`.
- `SSD_LIFE_MIN`: minimum accepted ATA SSD life attribute value, default `90`.

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

Run checks:

```bash
bash tests/smart_check_test.sh
bash tests/open_source_readiness_test.sh
docker compose config --quiet
docker compose build
```

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
