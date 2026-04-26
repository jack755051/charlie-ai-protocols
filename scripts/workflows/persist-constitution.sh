#!/usr/bin/env bash
#
# persist-constitution.sh — Pipeline step: take the schema-validated Project
# Constitution JSON produced upstream and write it to its two canonical
# homes:
#
#   1. Repo root  : .cap.constitution.yaml      (long-term governance SSOT)
#   2. CAP store  : ~/.cap/projects/<id>/constitutions/<ts>.json (snapshot)
#
# Reads:
#   - draft_constitution / project_constitution_json artifact path (from
#     CAP_WORKFLOW_INPUT_CONTEXT)
#   - upstream validation_report — used only to gate persistence; if the
#     report exists and contains a failure marker we refuse to write.
#
# Behavior:
#   - Locate the constitution JSON (either explicit fence or
#     project_constitution_json artifact path).
#   - Convert JSON → YAML for the repo-level .cap.constitution.yaml.
#   - Write the original JSON to the timestamped snapshot path.
#   - Emit a markdown report listing both written paths so downstream task
#     workflows can resolve them.
#
# Exit codes:
#   - 0  : success
#   - 40 : git_operation_failed-class — missing input artifact, JSON parse
#          error, write failure, or validation report indicates failure.
#
# This step does NOT allow AI fallback; if persistence fails the workflow
# must halt so the operator can investigate. The upstream draft is already
# preserved in the workflow output dir.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-persist_constitution}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"

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

PATH_HELPER="${CAP_ROOT}/scripts/cap-paths.sh"

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Constitution Persistence Report\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: git_operation_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  exit 40
}

extract_artifact_path() {
  local context="$1"
  local artifact_name="$2"
  printf '%s' "${context}" \
    | awk -v want="${artifact_name}" '
        $0 ~ "^[[:space:]]*-[[:space:]]*"want":[[:space:]]*step=" {
          if (match($0, /path=([^[:space:]]+)/, arr)) {
            print arr[1]
            exit
          }
        }
        $0 ~ "^[[:space:]]*"want":[[:space:]]*step=" {
          if (match($0, /path=([^[:space:]]+)/, arr)) {
            print arr[1]
            exit
          }
        }
      '
}

extract_constitution_json_from_markdown() {
  local path="$1"
  local fenced
  fenced="$(awk '
    BEGIN { inside = 0 }
    /<<<CONSTITUTION_JSON_BEGIN>>>/ { inside = 1; next }
    /<<<CONSTITUTION_JSON_END>>>/   { inside = 0; next }
    inside == 1 { print }
  ' "${path}")"
  if [ -n "${fenced}" ]; then
    printf '%s\n' "${fenced}"
    return
  fi

  awk '
    BEGIN { inside = 0; emitted = 0 }
    /^```json[[:space:]]*$/ { inside = 1; next }
    inside == 1 && /^```[[:space:]]*$/ { exit }
    inside == 1 { print }
  ' "${path}"
}

print_header

# 1. resolve validation report (if any) and refuse on failure.
validation_path="$(extract_artifact_path "${input_context}" "constitution_validation_report")"
if [ -n "${validation_path}" ] && [ -f "${validation_path}" ]; then
  if grep -q 'condition: git_operation_failed' "${validation_path}"; then
    fail_with "upstream_validation_failed" \
      "validation report indicates failure: ${validation_path}"
  fi
fi

# 2. resolve constitution JSON source artifact.
artifact_path=""
for name in project_constitution_json project_constitution; do
  candidate="$(extract_artifact_path "${input_context}" "${name}")"
  if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
    artifact_path="${candidate}"
    break
  fi
done

if [ -z "${artifact_path}" ] || [ ! -f "${artifact_path}" ]; then
  fail_with "missing_draft_artifact" \
    "could not resolve project_constitution artifact from CAP_WORKFLOW_INPUT_CONTEXT"
fi

# 3. extract JSON. Accept either:
#    a) a markdown artifact with the explicit fence pair,
#    b) a markdown artifact with a fenced ```json block,
#    c) a plain .json file.
tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT

case "${artifact_path}" in
  *.json)
    cp "${artifact_path}" "${tmp_json}"
    ;;
  *)
    extract_constitution_json_from_markdown "${artifact_path}" > "${tmp_json}"
    ;;
esac

if [ ! -s "${tmp_json}" ]; then
  fail_with "no_constitution_json_block" \
    "could not extract JSON from artifact: ${artifact_path}"
fi

# 4. parse JSON to validate structure and to derive project_id.
project_id_from_json="$("${PYTHON_BIN}" -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    pid = data.get("project_id", "")
    print(pid)
except Exception as exc:
    print(f"__error__:{exc}", file=sys.stderr)
    sys.exit(1)
' "${tmp_json}" 2>&1)" || fail_with "constitution_json_parse_error" "${project_id_from_json}"

if [ -z "${project_id_from_json}" ]; then
  fail_with "missing_project_id" "constitution JSON must contain non-empty project_id"
fi

# 5. resolve target paths.
REPO_TARGET="${CAP_ROOT}/.cap.constitution.yaml"
if [ -x "${PATH_HELPER}" ]; then
  CAP_HOME="${CAP_HOME:-${HOME}/.cap}"
  CONSTITUTION_DIR="${CAP_HOME}/projects/${project_id_from_json}/constitutions"
else
  CONSTITUTION_DIR="${HOME}/.cap/projects/${project_id_from_json}/constitutions"
fi

mkdir -p "${CONSTITUTION_DIR}" || fail_with "snapshot_dir_create_failed" "${CONSTITUTION_DIR}"

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
SNAPSHOT_PATH="${CONSTITUTION_DIR}/${TIMESTAMP}.json"

# 6. write snapshot (raw JSON, pretty-printed).
"${PYTHON_BIN}" -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
' "${tmp_json}" "${SNAPSHOT_PATH}" || fail_with "snapshot_write_failed" "${SNAPSHOT_PATH}"

# 7. write repo-level YAML. We refuse to overwrite an existing
#    .cap.constitution.yaml unless CAP_CONSTITUTION_OVERWRITE=1 is set, so the
#    bootstrap path doesn't silently nuke the platform's own constitution.
if [ -f "${REPO_TARGET}" ] && [ "${CAP_CONSTITUTION_OVERWRITE:-0}" != "1" ]; then
  printf 'repo_target_skipped: %s (already exists; set CAP_CONSTITUTION_OVERWRITE=1 to replace)\n' "${REPO_TARGET}"
  REPO_WRITTEN=0
else
  "${PYTHON_BIN}" -c '
import json, sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
with open(dst, "w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, allow_unicode=True, sort_keys=False)
' "${tmp_json}" "${REPO_TARGET}" || fail_with "repo_target_write_failed" "${REPO_TARGET}"
  REPO_WRITTEN=1
fi

# 8. emit report.
printf 'condition: success\n'
printf 'snapshot_path: %s\n' "${SNAPSHOT_PATH}"
printf 'repo_target: %s\n' "${REPO_TARGET}"
printf 'repo_written: %s\n' "${REPO_WRITTEN}"
printf 'project_id: %s\n\n' "${project_id_from_json}"

printf '## 交接摘要\n\n'
printf -- '- agent_id: shell-persist-constitution\n'
printf -- '- task_summary: persist validated Project Constitution to repo SSOT and runtime snapshot\n'
printf -- '- output_paths:\n'
printf '  - %s\n' "${REPO_TARGET}"
printf '  - %s\n' "${SNAPSHOT_PATH}"
printf -- '- result: success\n'
printf -- '- project_id: %s\n' "${project_id_from_json}"

exit 0
