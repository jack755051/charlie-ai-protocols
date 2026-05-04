#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/cap-artifact.sh list                                [--json] [--runtime-state <path>]
  bash scripts/cap-artifact.sh inspect <artifact_name>             [--json] [--runtime-state <path>]
  bash scripts/cap-artifact.sh by-step <step_id>                   [--json] [--runtime-state <path>]

Read-only inspection over runtime-state.json artifact registry. Reuses
engine/session_inspector.py scanning convention; default scan walks
<CAP_HOME or ~/.cap>/projects/*/reports/workflows/*/*/runtime-state.json.
EOF
  exit 1
}

[ "$#" -ge 1 ] || usage

PYTHON_BIN="${PYTHON_BIN:-python3}"
exec "${PYTHON_BIN}" "${REPO_ROOT}/engine/artifact_inspector.py" "$@"
