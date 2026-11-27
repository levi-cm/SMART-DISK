#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [[ -f "${ROOT_DIR}/${path}" ]] || fail "missing ${path}"
}

require_line() {
    local path="$1" pattern="$2"
    grep -Eq "$pattern" "${ROOT_DIR}/${path}" || fail "${path} does not contain required pattern: ${pattern}"
}

reject_secret_patterns() {
    local path="$1"
    if grep -Eq '[0-9]{8,10}:[A-Za-z0-9_-]{25,}|TELEGRAM_BOT_TOKEN=.*[0-9]{8,10}:|^[[:space:]]*[0-9]{9,12}[[:space:]]*$' "${ROOT_DIR}/${path}"; then
        fail "${path} contains a token-like or real chat-id-like value"
    fi
}

require_file ".dockerignore"
require_file ".gitignore"
require_file ".env.example"
require_file "config/users.conf.example"
require_file "config/drives.conf.example"
require_file "scripts/healthcheck.sh"
require_file "README.md"
require_file "SECURITY.md"
require_file "LICENSE"
require_file ".github/workflows/ci.yml"
require_file "scripts/smart_result_lib.sh"
require_file "scripts/report_lib.sh"
require_file "tests/container_smoke_test.sh"

require_line ".gitignore" '^\.env$'
require_line ".gitignore" '^state/$'
require_line ".gitignore" '^config/drives\.conf$'
require_line ".gitignore" '^config/users\.conf$'
require_line ".dockerignore" '^\.env$'
require_line ".dockerignore" '^state/$'
require_line ".dockerignore" '^config/drives\.conf$'
require_line ".dockerignore" '^config/users\.conf$'
require_line ".dockerignore" '^\.git/$'

require_line "Dockerfile" '^COPY scripts/ /scripts/$'
require_line "Dockerfile" 'CMD /scripts/healthcheck.sh'
require_line "docker-compose.yml" 'read_only: true'
require_line "docker-compose.yml" 'cap_drop:'
require_line "docker-compose.yml" 'tmpfs:'
require_line "docker-compose.yml" 'SMART_POLICY: "\$\{SMART_POLICY:-paranoid\}"'
require_line "docker-compose.yml" 'BURST_COUNT: "\$\{BURST_COUNT:-10\}"'
require_line "docker-compose.yml" 'BURST_DELAY: "\$\{BURST_DELAY:-30\}"'
require_line "docker-compose.yml" '^[[:space:]]+- SYS_RAWIO$'
require_line "docker-compose.yml" '^[[:space:]]+- SYS_ADMIN$'
require_line "docker-compose.yml" '/dev/sda:/dev/sda'
require_line ".env.example" '^SMART_POLICY=paranoid$'
require_line ".env.example" '^# TELEGRAM_API_BASE=https://api\.telegram\.org$'
require_line "README.md" 'TELEGRAM_API_BASE'
require_line "README.md" '/full'

# shellcheck disable=SC2016 # Literal $f is part of the pattern.
for pattern in 'shellcheck' 'bash -n "\$f"' 'jq -e' 'for t in tests/\*_test\.sh' 'container_smoke_test\.sh' 'docker compose config --quiet'; do
    require_line ".github/workflows/ci.yml" "$pattern"
done

if grep -Eq '^[[:space:]]*-[[:space:]]*\./scripts:/scripts:ro' "${ROOT_DIR}/docker-compose.yml"; then
    fail "docker-compose.yml still bind-mounts scripts instead of using the built image"
fi

for path in ".env.example" "config/users.conf.example" "README.md" "SECURITY.md"; do
    reject_secret_patterns "$path"
done

# Fixtures and smoke-test inputs are public too: no tokens or real chat IDs.
while IFS= read -r path; do
    reject_secret_patterns "${path#"${ROOT_DIR}/"}"
done < <(find "${ROOT_DIR}/tests" -type f \( -name '*.json' -o -name '*.txt' -o -name '*.sh' -o -name '*.conf' \))

if grep -RInE 'log ".*(\$\{?chat_id\}?|\$\{?from_id\}?|\$\{?cb_id\}?|\$\{?text\}?)' "${ROOT_DIR}/scripts"/*.sh; then
    fail "scripts log Telegram identifiers or message text"
fi

if grep -RInE 'echo "\[telegram\].*(\$\{?chat_id\}?|\$\{?body\}?)' "${ROOT_DIR}/scripts"/*.sh; then
    fail "telegram.sh logs chat IDs or API response bodies"
fi

echo "open_source_readiness_test: ok"
