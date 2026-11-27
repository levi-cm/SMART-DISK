#!/usr/bin/env bash
# CI gate: `bash -n a.sh b.sh` only checks a.sh (b.sh becomes an argument),
# so the workflow must syntax-check each file on its own and run every test.
# shellcheck disable=SC2016 # Literal $f and globs are the patterns searched for.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "${ROOT_DIR}/tests/test_helpers.sh"

CI="${ROOT_DIR}/.github/workflows/ci.yml"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Why it matters: the multi-file form passes with a broken second file.
printf 'echo ok\n' > "${tmpdir}/a.sh"
printf 'if then fi (\n' > "${tmpdir}/b.sh"
bash -n "${tmpdir}/a.sh" "${tmpdir}/b.sh" || fail "expected 'bash -n a b' to miss the broken file"
if (for f in "${tmpdir}"/*.sh; do bash -n "$f" || exit 1; done) 2>/dev/null; then
    fail "per-file bash -n loop did not catch the broken file"
fi

# The workflow uses the per-file form only.
if grep -En 'bash -n [^"]*\*\.sh' "$CI"; then
    fail "ci.yml passes several files to one bash -n"
fi
grep -Eq 'for f in scripts/\*\.sh tests/\*\.sh tests/smoke/\*\.sh; do' "$CI" \
    || fail "ci.yml does not loop over scripts/, tests/ and tests/smoke/"
grep -Fq 'bash -n "$f" || exit 1' "$CI" || fail "ci.yml does not run bash -n per file"

# Every test file runs, including the offline container smoke test.
grep -Fq 'for t in tests/*_test.sh; do' "$CI" || fail "ci.yml does not run every tests/*_test.sh"
grep -Fq 'bash tests/container_smoke_test.sh' "$CI" || fail "ci.yml does not run the container smoke test"
grep -Fq 'shellcheck scripts/*.sh tests/*.sh tests/smoke/*.sh' "$CI" || fail "ci.yml shellcheck misses files"
grep -Fq 'docker compose config --quiet' "$CI" || fail "ci.yml does not render the compose file"

echo "ci_workflow_test: ok"
