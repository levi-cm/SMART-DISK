# Repository Guidelines

## Project Structure & Module Organization

This repository contains a Dockerized SMART disk watcher for Telegram alerts. The service is defined in `docker-compose.yml` and built from `Dockerfile`. Runtime logic lives in `scripts/`: `entrypoint.sh` runs scheduled scans, `bot_poller.sh` handles Telegram commands, `smart_check.sh` evaluates SMART health, `telegram.sh` sends messages, `state_lib.sh` manages locked JSON state, and `parse_updates.jq` parses Telegram updates. Static inputs are in `config/`: `drives.conf` lists devices such as `/dev/sda`, and local-only `users.conf` lists authorized Telegram chat IDs. Public-safe examples live next to the private files as `*.example`. Persistent runtime data is under ignored `state/`. `.env` stores secrets and is ignored.

## Build, Test, and Development Commands

- `docker compose config --quiet`: validate Compose syntax and environment interpolation.
- `docker compose build`: rebuild the `smart-watcher:latest` image.
- `docker compose up -d`: start or replace the `smart-watcher` container.
- `docker compose ps`: confirm the container is running and healthy.
- `docker compose logs -f smart-watcher`: follow watcher, scan, and Telegram polling logs.
- `docker compose exec smart-watcher /scripts/smart_check.sh /dev/sda`: run one SMART check inside the container.
- `bash tests/open_source_readiness_test.sh`: verify publish-safety guardrails such as ignored secrets, examples, docs, and image packaging.

## Coding Style & Naming Conventions

Scripts are Bash-first and use small functions with `snake_case` names. Keep variables uppercase for configuration and local lowercase for function internals. Follow the existing style: four-space indentation, quoted expansions, `local` variables, and explicit `jq` filters for JSON reads/writes. Keep script paths container-oriented (`/scripts`, `/config`, `/state`) because Compose mounts those directories read-only or writable as required.

## Testing Guidelines

Run `bash tests/smart_check_test.sh` for SMART parsing rules and `bash tests/open_source_readiness_test.sh` before publishing. For runtime changes, run `docker compose config --quiet`, rebuild when Dockerfile or `scripts/` change, restart with `docker compose up -d --build`, and check `docker compose ps` plus recent logs. The healthcheck validates entrypoint liveness and writable `/state` locking, so investigate unhealthy status before trusting scheduled alerts. For live SMART logic, test each configured drive with `/scripts/smart_check.sh`. For Telegram changes, verify `/help`, `/scan`, and `/heartbeat` from an authorized chat when credentials are available.

## Commit & Pull Request Guidelines

This directory is not a git repository, so no local commit convention is available. If git is initialized later, use short imperative commits such as `Add heartbeat toggle` or `Fix SMART temperature parsing`. Pull requests should describe operational impact, list verification commands run, and call out changes to mounted devices, `.env`, `config/users.conf`, or state handling.

## Security & Runtime Notes

Do not commit `.env`, `config/users.conf`, Telegram tokens, chat IDs, or `state/last_status.json`. The Docker build context also excludes these private files through `.dockerignore`. The container has `SYS_RAWIO`, `SYS_ADMIN`, and direct `/dev/sda`, `/dev/sdb`, and `/dev/sdc` access; treat device mapping changes as high impact. Keep `state_lib.sh` locking intact because the entrypoint and bot poller write the same JSON state file.
