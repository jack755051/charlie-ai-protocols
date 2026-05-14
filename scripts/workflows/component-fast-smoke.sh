#!/usr/bin/env bash
#
# component-fast-smoke.sh — P1b slice 6a runtime-smoke wrapper.
#
# Workflow-level wrapper that cd's into <project_root> and exec's
# the rendered scripts/runtime-smoke.sh. Forwards the smoke script's
# exit code unchanged so the workflow halt path stays consistent
# regardless of which probe inside the smoke script failed.
#
# Out of scope:
#   - This wrapper does NOT itself touch docker. The rendered
#     scripts/runtime-smoke.sh inside <project_root> owns the actual
#     compose up / probe / compose down sequence.
#   - This wrapper does NOT validate that the smoke script's probes
#     pass. It only enforces the path / executable contract and
#     forwards the exit code. The test gate stubs the smoke script
#     to exercise both the success and failure paths without docker.
#
# Usage:
#   scripts/workflows/component-fast-smoke.sh --project-root <path>
#
# Exit codes:
#   0   rendered smoke script exited 0.
#   2   --project-root missing / not a directory / usage error.
#   4   rendered scripts/runtime-smoke.sh missing or not executable.
#   *   propagated from the rendered smoke script (e.g. probe failure).

set -u

PROJECT_ROOT=""

usage() {
  cat >&2 <<EOF
Usage:
  $0 --project-root <path>
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root)  PROJECT_ROOT="${2:-}";  shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'error: unknown flag: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || { echo "error: --project-root required" >&2; usage; exit 2; }

if [ ! -d "$PROJECT_ROOT" ]; then
  printf 'error: project_root not a directory: %s\n' "$PROJECT_ROOT" >&2
  echo "condition: component_fast_smoke_failed"
  echo "result: failed"
  exit 2
fi

SMOKE_REL="scripts/runtime-smoke.sh"
SMOKE_ABS="${PROJECT_ROOT}/${SMOKE_REL}"

if [ ! -f "$SMOKE_ABS" ]; then
  printf 'error: rendered smoke script missing: %s\n' "$SMOKE_ABS" >&2
  echo "condition: component_fast_smoke_failed"
  echo "result: failed"
  exit 4
fi
if [ ! -x "$SMOKE_ABS" ]; then
  printf 'error: rendered smoke script not executable: %s\n' "$SMOKE_ABS" >&2
  echo "condition: component_fast_smoke_failed"
  echo "result: failed"
  exit 4
fi

# cd into project_root so the rendered smoke can resolve relative
# paths against its own project tree. Cd here, NOT inside the smoke
# script — the smoke script ships as a per-project template and
# should not have to know how it was invoked.
cd "$PROJECT_ROOT"

# Capture rc without `set -e` so we can always emit a summary line
# before propagating. Failure messages from the smoke script flow
# through stderr naturally; this wrapper does not re-format them.
smoke_rc=0
bash "${SMOKE_REL}" || smoke_rc=$?

if [ "$smoke_rc" -eq 0 ]; then
  echo "condition: ok"
  echo "project_root: $PROJECT_ROOT"
  echo "smoke_exit_code: 0"
  echo "result: success"
else
  echo "condition: component_fast_smoke_failed"
  echo "project_root: $PROJECT_ROOT"
  echo "smoke_exit_code: ${smoke_rc}"
  echo "result: failed"
fi

exit "$smoke_rc"
