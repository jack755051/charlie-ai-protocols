#!/usr/bin/env bash
#
# validate-supervisor-envelope.sh — Pipeline step: validate a supervisor
# orchestration envelope artifact (P3 #4).
#
# Reads:
#   - supervisor_orchestration_envelope artifact path (from CAP_WORKFLOW_INPUT_CONTEXT)
#   - schemas/supervisor-orchestration.schema.yaml
#
# Pipeline (all delegated to engine/supervisor_envelope.py — this shell
# is a thin wrapper that maps stage failures onto the standard P0a
# exit-41 contract; the Python module is the SSOT for fence rules,
# jsonschema verdict shape, and drift semantics):
#
#   1. Resolve artifact path from input context (named
#      `supervisor_orchestration_envelope`, with a fallback to the
#      first `path=...` token in the context — same convention as
#      validate-constitution.sh).
#   2. Extract envelope JSON from the markdown / response artifact via
#      the explicit <<<SUPERVISOR_ORCHESTRATION_BEGIN/END>>> fence pair
#      (no ```json``` fallback — see agent-skills/01-supervisor-agent.md
#      §3.8 for the producer rule).
#   3. Validate the extracted payload against
#      schemas/supervisor-orchestration.schema.yaml using jsonschema
#      Draft 2020-12.
#   4. Drift check: confirm envelope.task_id and envelope.source_request
#      mirror their nested task_constitution counterparts.
#
# Exit codes (per policies/workflow-executor-exit-codes.md):
#   - 0  : envelope is well-formed, schema-valid, and drift-free
#   - 41 : schema_validation_failed for any of the four failure
#          classes below (this script is schema-class):
#            - missing_envelope_artifact
#            - envelope_extraction_failed
#            - schema_validation_failed
#            - envelope_drift_detected
#
# Out of scope (deferred to P3 #5):
#   - Snapshot writer for ~/.cap/projects/<id>/orchestrations/<stamp>/
#   - Wiring this executor into per-stage workflow YAML
#   - Compile / bind reading the envelope as their authoritative input

set -u

step_id="${CAP_WORKFLOW_STEP_ID:-validate_supervisor_envelope}"
input_context="${CAP_WORKFLOW_INPUT_CONTEXT:-}"

CAP_ROOT="${CAP_ROOT:-}"
if [ -z "${CAP_ROOT}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CAP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
SCHEMA_PATH="${CAP_ROOT}/schemas/supervisor-orchestration.schema.yaml"
HELPER_MODULE_DIR="${CAP_ROOT}"
VENV_PY="${CAP_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

print_header() {
  printf '# %s\n\n' "${step_id}"
  printf '## Supervisor Orchestration Envelope Validation Report\n\n'
}

fail_with() {
  local reason="$1"
  shift
  printf 'condition: schema_validation_failed\n'
  printf 'reason: %s\n' "${reason}"
  for line in "$@"; do
    printf 'detail: %s\n' "${line}"
  done
  # exit 41 = schema_validation_failed (schema-class executor per
  # policies/workflow-executor-exit-codes.md). Drift, extraction
  # failures, and missing artifacts all collapse to this single class
  # because they share the "envelope cannot be safely consumed" root
  # cause.
  exit 41
}

# Resolve a named artifact path from CAP_WORKFLOW_INPUT_CONTEXT. Mirrors
# validate-constitution.sh's helper so the two schema-class executors
# behave identically when input_context is malformed.
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

# ── main ──

print_header

# 1. resolve artifact path
artifact_path=""
candidate="$(extract_artifact_path "${input_context}" "supervisor_orchestration_envelope")"
if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
  artifact_path="${candidate}"
fi
if [ -z "${artifact_path}" ]; then
  artifact_path="$(fallback_first_artifact_path "${input_context}")"
fi
if [ -z "${artifact_path}" ] || [ ! -f "${artifact_path}" ]; then
  fail_with "missing_envelope_artifact" \
    "could not resolve supervisor_orchestration_envelope artifact from CAP_WORKFLOW_INPUT_CONTEXT"
fi

printf 'envelope_artifact: %s\n' "${artifact_path}"
printf 'schema: %s\n\n' "${SCHEMA_PATH}"

# 2-4. Delegate fence extraction + jsonschema + drift to the Python
# helper. We capture stdout (JSON envelope of stage / ok / errors)
# from each stage and read the `ok` field; the helper writes a single
# JSON object per invocation so a single-line jq-free parse keeps the
# wrapper portable.

run_helper_stage() {
  local stage="$1"
  shift
  ( cd "${HELPER_MODULE_DIR}" && \
    "${PYTHON_BIN}" -m engine.supervisor_envelope "${stage}" --input "${artifact_path}" "$@" )
}

read_ok() {
  local json="$1"
  printf '%s' "${json}" | "${PYTHON_BIN}" -c '
import json, sys
data = json.loads(sys.stdin.read())
print("true" if data.get("ok") is True else "false")
' 2>/dev/null
}

# Stage A: extract — surfaces fence / parse errors
extract_json="$(run_helper_stage extract 2>&1)"
extract_ok="$(read_ok "${extract_json}")"
if [ "${extract_ok}" != "true" ]; then
  printf '### Extraction Output\n\n```json\n%s\n```\n\n' "${extract_json}"
  fail_with "envelope_extraction_failed" \
    "engine.supervisor_envelope extract reported ok=false; see Extraction Output above"
fi

# Stage B: validate — schema verdict
validate_json="$(run_helper_stage validate --schema-path "${SCHEMA_PATH}" 2>&1)"
validate_ok="$(read_ok "${validate_json}")"
printf '### Validator Output\n\n```json\n%s\n```\n\n' "${validate_json}"
if [ "${validate_ok}" != "true" ]; then
  fail_with "schema_validation_failed" \
    "engine.supervisor_envelope validate reported ok=false; see Validator Output above"
fi

# Stage C: drift — task_id / source_request mirror check
drift_json="$(run_helper_stage drift 2>&1)"
drift_ok="$(read_ok "${drift_json}")"
printf '### Drift Output\n\n```json\n%s\n```\n\n' "${drift_json}"
if [ "${drift_ok}" != "true" ]; then
  fail_with "envelope_drift_detected" \
    "engine.supervisor_envelope drift reported ok=false; see Drift Output above"
fi

printf 'condition: schema_validation_passed\n'
printf 'envelope_artifact: %s\n' "${artifact_path}"
printf 'schema: %s\n' "${SCHEMA_PATH}"
exit 0
