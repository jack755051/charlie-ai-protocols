#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_FILE="${CAP_ROOT}/.cap.agents.json"
VENV_PYTHON="${CAP_ROOT}/.venv/bin/python"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"

if [ -x "${VENV_PYTHON}" ]; then
  PYTHON_BIN="${VENV_PYTHON}"
else
  PYTHON_BIN="python3"
fi

usage() {
  cat <<'EOF' >&2
Usage:
  bash scripts/cap-registry.sh show
  bash scripts/cap-registry.sh get <agent_alias>
  bash scripts/cap-registry.sh list
EOF
  exit 1
}

[ -f "${REGISTRY_FILE}" ] || {
  echo "找不到 agent registry：${REGISTRY_FILE}" >&2
  exit 1
}

case "${1:-}" in
  show)
    [ "$#" -eq 1 ] || usage
    cat "${REGISTRY_FILE}"
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    "${PYTHON_BIN}" "${STEP_PY}" registry-list "${REGISTRY_FILE}"
    ;;
  get)
    [ "$#" -eq 2 ] || usage
    "${PYTHON_BIN}" "${STEP_PY}" registry-get "${REGISTRY_FILE}" "$2"
    ;;
  *)
    usage
    ;;
esac
