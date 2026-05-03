#!/usr/bin/env bash
#
# cap-storage-health.sh — Shell entry point for the CAP storage health
# check core defined in engine/storage_health.py (P1 #4).
#
# Thin wrapper: forwards args to the Python module and lets the module
# decide both stdout content and exit code. We avoid re-implementing the
# diagnostic logic in shell so producer/consumer policy stays in lock-step.
#
# Exit code policy (mirrors policies/workflow-executor-exit-codes.md):
#   0  — no errors (warnings allowed unless --strict is passed)
#   1  — generic storage error (missing dirs / unwritable / missing ledger)
#   41 — schema-class issue (malformed / forward-incompat / drift)
#   53 — origin collision detected by the diagnostic
#
# Usage:
#   bash scripts/cap-storage-health.sh [--format text|json|yaml] [--strict] \
#                                       [--project-root PATH] \
#                                       [--cap-home PATH] \
#                                       [--project-id ID] \
#                                       [--stale-days N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HEALTH_MODULE="${REPO_ROOT}/engine/storage_health.py"

if [ ! -f "${HEALTH_MODULE}" ]; then
  echo "cap-storage-health: error — ${HEALTH_MODULE} not found" >&2
  exit 1
fi

# Default project_root to caller's working directory so the wrapper can
# be invoked from inside any consumer repo (cap-paths-style behaviour).
HAS_PROJECT_ROOT=0
for arg in "$@"; do
  case "${arg}" in
    --project-root|--project-root=*)
      HAS_PROJECT_ROOT=1
      break
      ;;
  esac
done

ARGS=("$@")
if [ "${HAS_PROJECT_ROOT}" -eq 0 ]; then
  ARGS+=(--project-root "$(pwd)")
fi

exec python3 "${HEALTH_MODULE}" "${ARGS[@]}"
