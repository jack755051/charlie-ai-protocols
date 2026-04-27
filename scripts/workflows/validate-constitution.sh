#!/usr/bin/env bash
#
# validate-constitution.sh — Pipeline step: validate the Project Constitution
# JSON produced by the upstream `draft_constitution` step against
# `schemas/project-constitution.schema.yaml`.
#
# Reads:
#   - draft_constitution artifact path (from CAP_WORKFLOW_INPUT_CONTEXT)
#   - schemas/project-constitution.schema.yaml
#
# Behavior:
#   - Extract JSON from the markdown artifact. The authoritative format is
#     a single <<<CONSTITUTION_JSON_BEGIN>>> ... <<<CONSTITUTION_JSON_END>>>
#     fence pair. As a fallback we accept exactly one fenced ```json block;
#     multiple ```json blocks (or unbalanced explicit fences) are rejected
#     because we cannot safely guess which block is the canonical
#     constitution.
#   - Run `step_runtime validate-constitution` with jsonschema.
#   - On pass: emit a confirmation report and exit 0.
#   - On fail: emit the schema errors, exit 40 (git_operation_failed-class
#     so workflow halts; we deliberately do not allow AI fallback for
#     constitution validation — bad constitutions must surface, not be
#     auto-rewritten).
#
# Exit codes follow docs/policies/workflow-executor-exit-codes.md.
# TODO: when the exit-code policy gains a dedicated `60: schema_validation_failed`,
#       migrate this script away from re-using 40.

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-validate_constitution}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
SCHEMA_PATH="${CAP_ROOT}/schemas/project-constitution.schema.yaml"
STEP_PY="${CAP_ROOT}/engine/step_runtime.py"
VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Constitution Schema Validation Report\n\n'
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

# Resolve artifact path for `project_constitution` (or `project_constitution_json`)
# from the resolved input context. Falls back to scanning for any compose-style
# artifact path if the named lookup fails.
extract_artifact_path() {
  local context="$1"
  local artifact_name="$2"
  printf '%s' "${context}" | "${PYTHON_BIN}" -c '
import re
import sys

want = sys.argv[1]
for line in sys.stdin.read().splitlines():
    if want in line and "path=" in line:
        m = re.search(r"path=([^\s]+)", line)
        if m:
            print(m.group(1))
            raise SystemExit(0)
print("")
' "${artifact_name}"
}

fallback_first_artifact_path() {
  local context="$1"
  printf '%s' "${context}" | grep -oE 'path=[^ ]+' | sed 's/^path=//' | head -n 1
}

# Pre-flight fence check. fail_with-style halt MUST be done in main (not inside
# this function) because main redirects extract_constitution_json's stdout into
# the temp file; if we halted here, the failure message would be silently
# captured into the JSON sink instead of surfaced to the step output.
check_constitution_fences() {
  local path="$1"
  local explicit_begin_count
  local explicit_end_count
  local json_fence_count

  explicit_begin_count="$(grep -c '^<<<CONSTITUTION_JSON_BEGIN>>>[[:space:]]*$' "${path}" 2>/dev/null || true)"
  explicit_end_count="$(grep -c '^<<<CONSTITUTION_JSON_END>>>[[:space:]]*$' "${path}" 2>/dev/null || true)"
  json_fence_count="$(grep -cE '^```json[[:space:]]*$' "${path}" 2>/dev/null || true)"
  : "${explicit_begin_count:=0}"
  : "${explicit_end_count:=0}"
  : "${json_fence_count:=0}"

  printf '%s|%s|%s\n' "${explicit_begin_count}" "${explicit_end_count}" "${json_fence_count}"
}

# Extract the constitution JSON. Caller must have already validated fence
# counts via check_constitution_fences and proven exactly one fence source
# is present (either one explicit pair or one fenced ```json block).
extract_constitution_json() {
  local path="$1"
  local explicit_count="$2"

  if [ "${explicit_count}" -eq 1 ]; then
    awk '
      BEGIN { inside = 0 }
      /^<<<CONSTITUTION_JSON_BEGIN>>>[[:space:]]*$/ { inside = 1; next }
      /^<<<CONSTITUTION_JSON_END>>>[[:space:]]*$/   { inside = 0; next }
      inside == 1 { print }
    ' "${path}"
    return
  fi

  awk '
    BEGIN { inside = 0 }
    /^```json[[:space:]]*$/ { inside = 1; next }
    inside == 1 && /^```[[:space:]]*$/ { exit }
    inside == 1 { print }
  ' "${path}"
}

# ── main ──

print_header

# 1. resolve artifact path
artifact_path=""
for name in project_constitution_json project_constitution; do
  candidate="$(extract_artifact_path "${input_context}" "${name}")"
  if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
    artifact_path="${candidate}"
    break
  fi
done
if [ -z "${artifact_path}" ]; then
  artifact_path="$(fallback_first_artifact_path "${input_context}")"
fi
if [ -z "${artifact_path}" ] || [ ! -f "${artifact_path}" ]; then
  fail_with "missing_draft_artifact" \
    "could not resolve draft_constitution artifact from CAP_WORKFLOW_INPUT_CONTEXT"
fi

printf 'draft_artifact: %s\n' "${artifact_path}"
printf 'schema: %s\n\n' "${SCHEMA_PATH}"

# 2. fence pre-flight (must run before redirecting stdout into the JSON sink)
IFS='|' read -r explicit_begin explicit_end json_fences < <(check_constitution_fences "${artifact_path}")

if [ "${explicit_begin}" -gt 1 ] || [ "${explicit_end}" -gt 1 ]; then
  fail_with "multiple_explicit_fences" \
    "artifact contains more than one <<<CONSTITUTION_JSON_BEGIN/END>>> pair; only one constitution JSON block is allowed"
fi
if [ "${explicit_begin}" -ne "${explicit_end}" ]; then
  fail_with "unbalanced_explicit_fences" \
    "artifact has unbalanced <<<CONSTITUTION_JSON_BEGIN/END>>> markers (begin=${explicit_begin}, end=${explicit_end})"
fi
if [ "${explicit_begin}" -eq 0 ] && [ "${json_fences}" -gt 1 ]; then
  fail_with "multiple_json_fenced_blocks" \
    "artifact contains ${json_fences} \`\`\`json blocks but no explicit <<<CONSTITUTION_JSON_BEGIN/END>>> fence; please wrap the canonical constitution JSON with the explicit fence pair to disambiguate"
fi
if [ "${explicit_begin}" -eq 0 ] && [ "${json_fences}" -eq 0 ]; then
  fail_with "no_constitution_json_block" \
    "artifact is missing both <<<CONSTITUTION_JSON_BEGIN>>>...<<<CONSTITUTION_JSON_END>>> and a fenced \`\`\`json block; the AI agent must emit one of these around the constitution JSON"
fi

# 3. extract JSON to a temp file
tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT

extract_constitution_json "${artifact_path}" "${explicit_begin}" > "${tmp_json}"

if [ ! -s "${tmp_json}" ]; then
  fail_with "empty_constitution_json_block" \
    "fence detected but the body between markers is empty"
fi

# 4. validate via step_runtime
result_json="$("${PYTHON_BIN}" "${STEP_PY}" validate-constitution "${tmp_json}" "${SCHEMA_PATH}")"
exit_code=$?

# 5. report + decide
printf '### Validator Output\n\n```json\n%s\n```\n\n' "${result_json}"

ok="$(printf '%s' "${result_json}" | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"

if [ "${ok}" = "True" ]; then
  printf 'condition: success\nresult: constitution_valid\n\n'
  printf '## 交接摘要\n\n'
  printf -- '- agent_id: shell-validate-constitution\n'
  printf -- '- task_summary: validate Project Constitution JSON against schema\n'
  printf -- '- output_paths:\n'
  printf '  - %s\n' "${CAP_WORKFLOW_OUTPUT_PATH:-stdout}"
  printf -- '- result: success\n'
  printf -- '- validated_artifact: %s\n' "${artifact_path}"
  exit 0
fi

# Validation failure: surface schema errors and halt; do not allow AI fallback
# (a constitution that fails schema must be regenerated by re-running upstream,
# not silently rewritten).
errors_pretty="$(printf '%s' "${result_json}" | "${PYTHON_BIN}" -c '
import json, sys
data = json.load(sys.stdin)
for e in data.get("errors", []):
    print(f"  - {e}")
')"

printf 'condition: git_operation_failed\n'
printf 'reason: constitution_schema_invalid\n'
printf 'schema_errors:\n%s\n' "${errors_pretty}"
printf 'detail: rerun draft_constitution step with corrected supervisor prompt; do not auto-rewrite\n'
printf '_step_runtime_exit: %s\n' "${exit_code}"
exit 40
