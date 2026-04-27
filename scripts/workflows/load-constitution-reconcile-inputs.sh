#!/usr/bin/env bash
#
# load-constitution-reconcile-inputs.sh — Pipeline step:
# collect the current Project Constitution plus an optional supplemental prompt
# for the reconcile workflow.
#
# Reads:
#   - current repo .cap.constitution.yaml
#   - CAP_PROJECT_CONSTITUTION_ADDENDUM_PATH (optional)
#   - CAP_WORKFLOW_USER_PROMPT (fallback supplemental prompt)
#
# Emits a markdown artifact that the reconcile AI step can consume without
# treating the supplemental prompt as part of the constitution SSOT.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-load_reconcile_inputs}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi

VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

CONSTITUTION_PATH="${CAP_ROOT}/.cap.constitution.yaml"
ADDENDUM_PATH="${CAP_PROJECT_CONSTITUTION_ADDENDUM_PATH:-}"
USER_PROMPT="${CAP_WORKFLOW_USER_PROMPT:-}"

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Constitution Reconcile Inputs\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: %s\n' "${reason}"
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

read_project_meta() {
  "${PYTHON_BIN}" - "${CAP_ROOT}/.cap.project.yaml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("project_id: -")
    print("project_name: -")
    raise SystemExit(0)

project_id = "-"
project_name = "-"
for line in path.read_text(encoding="utf-8").splitlines():
    if line.startswith("project_id:"):
        project_id = line.split(":", 1)[1].strip().strip('"').strip("'")
    elif line.startswith("project_name:"):
        project_name = line.split(":", 1)[1].strip().strip('"').strip("'")
print(f"project_id: {project_id}")
print(f"project_name: {project_name}")
PY
}

read_supplemental_prompt() {
  if [ -n "${ADDENDUM_PATH}" ] && [ -f "${ADDENDUM_PATH}" ]; then
    printf '%s\n' "${ADDENDUM_PATH}"
    return
  fi

  if [ -n "${USER_PROMPT}" ]; then
    printf '__WORKFLOW_PROMPT__\n'
    printf '%s\n' "${USER_PROMPT}"
    return
  fi

  printf '__EMPTY__\n'
}

print_header

if [ ! -f "${CONSTITUTION_PATH}" ]; then
  fail_with "missing_current_constitution" \
    "expected current constitution at ${CONSTITUTION_PATH}" \
    "run project-constitution first before reconcile"
fi

project_meta="$(read_project_meta)"
supplemental_marker_and_text="$(read_supplemental_prompt)"
supplemental_marker="$(printf '%s\n' "${supplemental_marker_and_text}" | head -n 1)"

printf 'constitution_path: %s\n' "${CONSTITUTION_PATH}"
printf 'supplemental_prompt_source: %s\n' "${supplemental_marker}"
printf '\n## Project Meta\n\n'
printf '%s\n' "${project_meta}" | sed 's/^/- /'

printf '\n## Current Constitution (verbatim)\n\n'
cat "${CONSTITUTION_PATH}"
printf '\n'

printf '## Supplemental Prompt\n\n'
case "${supplemental_marker}" in
  __WORKFLOW_PROMPT__)
    printf '%s\n' "${supplemental_marker_and_text}" | sed '1d'
    printf '\n'
    ;;
  __EMPTY__)
    printf '_（未提供補充 prompt；本次 reconcile 只會依現有 constitution 重新整理）_\n\n'
    ;;
  *)
    if [ -f "${supplemental_marker}" ]; then
      cat "${supplemental_marker}"
      printf '\n'
    else
      printf '_（找不到補充 prompt 檔案：%s）_\n\n' "${supplemental_marker}"
    fi
    ;;
esac

printf '## Reconcile Rules\n\n'
printf '%s\n' \
  '- preserve existing stable identifiers unless the supplemental prompt explicitly requests a rename' \
  '- keep source_of_truth / runtime_workspace / workflow_policy aligned with the existing constitution unless the addendum explicitly changes them' \
  '- do not add an empty additional prompt file into the constitution; supplemental input stays external' \
  '- the reconcile step must emit one schema-valid constitution draft and then stop'

exit 0
