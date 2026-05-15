#!/usr/bin/env bash
#
# cap-provider-preflight.sh — workflow provider readiness preflight helper.
#
# Source this file from a parent shell; it exposes three functions:
#
#   workflow_has_ai_step  <plan_json>
#       0 if any step (including a fallback) reports executor=ai;
#       1 otherwise.
#
#   provider_preflight_check  <cli_name> <doctor_json>
#       Looks up the doctor entry for <cli_name> and emits a
#       semicolon-separated key=value line to stdout:
#         result=<halt|warn|ok|unknown_cli>
#         state=<state>
#         remediation=<text>
#         cli_path=<path>            (optional, when known)
#         version=<text>             (optional, when known)
#         failure_reason=<text>      (optional, when state=error)
#       Exit code:
#         0  ok       (state=auth_ok)
#         1  warn     (state=auth_unknown — workflow may proceed under
#                     operator's risk per ADR-3 §4 Q6)
#         2  halt     (state in {provider_missing, auth_required, error})
#         3  unknown_cli   (cli_name not present in doctor JSON; this is
#                     itself a halt condition for callers but is
#                     distinct in source so callers can route differently)
#         10 doctor_json_parse_error  (input not parseable JSON or wrong
#                     shape; structural protection)
#
#   provider_preflight_render_halt  <workflow_name> <cli> <result_line>
#       Prints a WORKFLOW PREFLIGHT BLOCKED — <workflow_name> block to
#       stdout mirroring the existing binding-blocked / binding-degraded
#       blocks in cap-workflow.sh so the operator sees a consistent UX.
#
# Ratified by:
#   - development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md
#     (ADR-3 — CAP owns readiness; AI-backed workflows MUST fail fast
#     before any provider call)
#   - schemas/provider-readiness.schema.yaml (the JSON contract that
#     `cap provider doctor --json` emits and this preflight consumes)
#
# Boundary (binding):
#   - This helper performs NO provider invocation, NO login, NO model
#     call. It only parses the doctor JSON the caller already produced.
#   - Doctor JSON itself is bound to the no_token / no_interactive /
#     no_mutation rules per ADR-3 §4 + scripts/cap-provider.sh.
#   - All keys in the result line are ASCII-safe (no embedded newlines /
#     semicolons in remediation text); callers parsing the line may
#     split on ';' without further escaping in v1 because the only
#     free-form field (remediation) ships from cap-provider.sh's own
#     fixed strings.

set -u

PROVIDER_PREFLIGHT_PYTHON_BIN="${PYTHON_BIN:-python3}"

workflow_has_ai_step() {
  local plan_json="$1"
  if [ -z "${plan_json}" ]; then
    return 1
  fi
  "${PROVIDER_PREFLIGHT_PYTHON_BIN}" - "${plan_json}" <<'PY'
import json
import sys

try:
    plan = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

binding = plan.get("binding") or {}
steps = binding.get("steps") or plan.get("steps") or []
for step in steps:
    if not isinstance(step, dict):
        continue
    executor = (step.get("executor") or "ai").strip().lower()
    if executor == "ai":
        sys.exit(0)
    fb = step.get("fallback") or {}
    if isinstance(fb, dict):
        fb_exec = (fb.get("executor") or "").strip().lower()
        if fb_exec == "ai":
            sys.exit(0)
sys.exit(1)
PY
}

provider_preflight_check() {
  local cli_name="$1"
  local doctor_json="$2"
  if [ -z "${doctor_json}" ]; then
    echo "result=doctor_json_parse_error;state=missing;remediation=doctor JSON empty"
    return 10
  fi
  "${PROVIDER_PREFLIGHT_PYTHON_BIN}" - "${cli_name}" "${doctor_json}" <<'PY'
import json
import sys

cli_name = sys.argv[1].strip()
raw = sys.argv[2]

def emit(result, state="", remediation="", cli_path="", version="", failure_reason=""):
    fields = [
        f"result={result}",
        f"state={state}",
        f"remediation={remediation}",
    ]
    if cli_path:
        fields.append(f"cli_path={cli_path}")
    if version:
        fields.append(f"version={version}")
    if failure_reason:
        fields.append(f"failure_reason={failure_reason}")
    print(";".join(fields))

try:
    report = json.loads(raw)
except Exception:
    emit("doctor_json_parse_error", "missing",
         "doctor JSON did not parse; rerun `cap provider doctor --json`")
    sys.exit(10)

if not isinstance(report, dict):
    emit("doctor_json_parse_error", "missing",
         "doctor JSON is not an object")
    sys.exit(10)

providers = report.get("providers")
if not isinstance(providers, list):
    emit("doctor_json_parse_error", "missing",
         "doctor JSON missing providers array")
    sys.exit(10)

match = None
for entry in providers:
    if isinstance(entry, dict) and entry.get("name") == cli_name:
        match = entry
        break

if match is None:
    emit(
        "unknown_cli",
        "missing",
        (
            f"selected provider `{cli_name}` is not in the doctor report; "
            "supported v1 names: claude, codex"
        ),
    )
    sys.exit(3)

state = (match.get("state") or "").strip()
remediation = match.get("remediation") or ""
cli_path = match.get("cli_path") or ""
version = match.get("version") or ""
failure_reason = match.get("failure_reason") or ""

if state == "auth_ok":
    emit("ok", state, remediation, cli_path, version)
    sys.exit(0)
if state == "auth_unknown":
    emit("warn", state, remediation, cli_path, version)
    sys.exit(1)
if state in ("provider_missing", "auth_required", "error"):
    emit("halt", state, remediation, cli_path, version, failure_reason)
    sys.exit(2)

# Unexpected state — treat as halt (conservative) so unrecognised
# future enum values do not silently proceed.
emit("halt", state or "unknown", remediation, cli_path, version, failure_reason)
sys.exit(2)
PY
}

# Extract a single field from a result line produced by
# provider_preflight_check. Used by the renderer + by callers that
# only need one field. Empty when not present.
_provider_preflight_field() {
  local field="$1" line="$2"
  "${PROVIDER_PREFLIGHT_PYTHON_BIN}" - "${field}" "${line}" <<'PY'
import sys
field = sys.argv[1]
line = sys.argv[2]
for piece in line.split(";"):
    if not piece:
        continue
    key, _, value = piece.partition("=")
    if key == field:
        print(value)
        sys.exit(0)
print("")
PY
}

provider_preflight_render_halt() {
  local workflow_name="$1" cli="$2" result_line="$3"
  local state remediation cli_path failure_reason
  state="$(_provider_preflight_field state "${result_line}")"
  remediation="$(_provider_preflight_field remediation "${result_line}")"
  cli_path="$(_provider_preflight_field cli_path "${result_line}")"
  failure_reason="$(_provider_preflight_field failure_reason "${result_line}")"

  printf '\n'
  printf 'WORKFLOW PREFLIGHT BLOCKED — %s\n' "${workflow_name}"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf 'blocked_reason: provider_not_ready\n'
  printf 'provider: %s\n' "${cli}"
  printf 'state: %s\n' "${state}"
  if [ -n "${cli_path}" ]; then
    printf 'cli_path: %s\n' "${cli_path}"
  fi
  if [ -n "${failure_reason}" ]; then
    printf 'failure_reason: %s\n' "${failure_reason}"
  fi
  printf 'remediation: %s\n' "${remediation}"
  printf '\n'
  printf 'Workflow halted before any provider call. No tokens were spent.\n'
  printf 'Source of truth: `cap provider doctor --json` (schema:\n'
  printf '  schemas/provider-readiness.schema.yaml).\n'
}

provider_preflight_render_warn() {
  local workflow_name="$1" cli="$2" result_line="$3"
  local state remediation
  state="$(_provider_preflight_field state "${result_line}")"
  remediation="$(_provider_preflight_field remediation "${result_line}")"
  printf '\n'
  printf 'WORKFLOW PREFLIGHT WARNING — %s\n' "${workflow_name}" >&2
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2
  printf 'provider: %s\n' "${cli}" >&2
  printf 'state: %s\n' "${state}" >&2
  printf 'remediation: %s\n' "${remediation}" >&2
  printf '\n' >&2
  printf 'Workflow will proceed; CAP cannot determine provider auth\n' >&2
  printf 'state without violating the no-token / no-interactive readiness\n' >&2
  printf 'rules. If the run halts mid-flight on auth failure, rerun the\n' >&2
  printf 'remediation step above and retry.\n' >&2
  printf '\n' >&2
}
