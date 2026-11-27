#!/usr/bin/env bash
# start.sh — runs inside the smoke-test container (started with --network none).
# Starts the mock Bot API on loopback with busybox nc, which the image already
# has, then hands over to the real entrypoint.
set -euo pipefail

port="${MOCK_PORT:-8081}"
mkdir -p "${MOCK_OUT:?}/requests"

nc -lk -s 127.0.0.1 -p "$port" -e /smoke/mock_bot_api.sh &

for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
        break
    fi
    sleep 0.1
done

exec /scripts/entrypoint.sh
