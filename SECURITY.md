# Security Policy

## Secrets

Keep these files private:

- `.env`
- `config/users.conf`
- `state/`
- Docker logs and copied scan reports

`.gitignore` and `.dockerignore` exclude the private files by default. Before publishing, run:

```bash
git status --ignored --short
bash tests/open_source_readiness_test.sh
```

## Telegram Token Safety

The Telegram bot token must only live in `.env`. The Docker image does not need it at build time, and the Dockerfile does not copy `.env` into the image.

If the token is ever committed, pasted into a public issue, uploaded in a zip, or exposed through a remote build context, revoke it immediately in BotFather and create a new token.

## Runtime Permissions

This container needs direct block-device access for `smartctl`. Keep the `devices:` list explicit and only map drives you intend to monitor. Avoid mounting `/dev` wholesale unless you understand the risk.

The container drops default Linux capabilities, retains `SYS_RAWIO` and `SYS_ADMIN` for supported raw ATA/NVMe `smartctl` access, runs with `no-new-privileges`, uses read-only config, and keeps writable state under `/state`. Do not remove either retained capability without testing every supported controller and drive path; ioctl requirements vary by hardware and transport.

SMART evidence and Telegram wording use `advisory`, `degraded`, and `critical` levels. Historical counters remain visible warnings but are not presented as proof of imminent failure. The default `SMART_POLICY=paranoid` keeps alert coverage and configurable bursts; `balanced` changes alert intensity, not data collection or raw-device access.
