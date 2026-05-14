#!/usr/bin/env bash
#
# ${PROJECT_ID} runtime smoke test.
# Brings up the compose stack, probes /api/health + /api/feedback, and
# tears the stack down. Exits non-zero on any probe failure so the
# Component Fast Path deterministic_compliance_checklist gate can fail
# the workflow before the AI compact_review step runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_PORT="${BACKEND_PORT:-8080}"
PROBE_RETRIES="${SMOKE_PROBE_RETRIES:-20}"
PROBE_SLEEP_SECONDS="${SMOKE_PROBE_SLEEP:-3}"

cleanup() {
  ( cd "${PROJECT_ROOT}" && docker compose down --remove-orphans >/dev/null 2>&1 || true )
}
trap cleanup EXIT

cd "${PROJECT_ROOT}"

echo "[smoke] starting compose stack…"
docker compose up -d --build backend frontend

probe() {
  local label="$1" url="$2"
  local attempt=0
  while [ "${attempt}" -lt "${PROBE_RETRIES}" ]; do
    if curl --silent --fail "${url}" >/dev/null; then
      echo "[smoke] ${label} OK (${url})"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "${PROBE_SLEEP_SECONDS}"
  done
  echo "[smoke] ${label} FAILED after ${PROBE_RETRIES} attempts (${url})" >&2
  return 1
}

probe "backend /api/health" "http://localhost:${BACKEND_PORT}/api/health"

probe "frontend root" "http://localhost:${FRONTEND_PORT:-3000}/"

echo "[smoke] submitting one feedback entry…"
curl --silent --fail --show-error \
  -H "Content-Type: application/json" \
  -X POST "http://localhost:${BACKEND_PORT}/api/feedback" \
  -d '{"rating":5,"comment":"smoke"}' \
  >/dev/null

echo "[smoke] all probes passed"
