#!/usr/bin/env bash
#
# smoke-per-stage.sh — Single-command smoke check for the per-stage workflow
# series introduced in v0.19.x.
#
# Runs (in order):
#   1. cap workflow bind project-spec-pipeline                   (must end in ready)
#   2. cap workflow bind project-implementation-pipeline         (must end in ready)
#   3. cap workflow bind project-qa-pipeline                     (must end in ready)
#   4. tests/scripts/test-persist-task-constitution.sh           (must report 13/13)
#   5. tests/scripts/test-emit-handoff-ticket.sh                 (must report 15/15)
#   6. tests/e2e/test-project-spec-pipeline-deterministic.sh     (must report 40/40)
#   7. tests/e2e/test-ticket-consumption.sh                      (must report 22/22)
#
# Resolution order for the bind command:
#   1. `cap` on PATH (installed via cap installer)
#   2. `${REPO_ROOT}/scripts/cap-workflow.sh` (in-repo fallback for CI / fresh
#      checkouts that have not run the installer yet)
#   3. WARN + skip if neither is available
# The bash fixture suites always run regardless, so the wrapper still serves
# as a hermetic CI gate even on a system without cap installed.
#
# Exit codes:
#   0  all checks passed (or skipped where appropriate)
#   1  at least one check failed
#
# This wrapper does NOT replace integration / e2e testing of `cap workflow run`;
# it is a "ready to attempt e2e" pre-flight.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

pass_count=0
fail_count=0
warn_count=0

report_pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
report_fail() { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; fail_count=$((fail_count + 1)); }
report_warn() { echo "  WARN: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; warn_count=$((warn_count + 1)); }

# Resolve the bind invocation once, prefer `cap` on PATH, fall back to the
# in-repo cap-workflow.sh, return non-zero (and set BIND_SKIP_REASON) when
# neither is available so the caller can WARN-skip rather than fail-skip.
BIND_INVOKER=""
BIND_SKIP_REASON=""
resolve_bind_invoker() {
  if command -v cap >/dev/null 2>&1; then
    BIND_INVOKER="cap_path"
    return 0
  fi
  if [ -f "${REPO_ROOT}/scripts/cap-workflow.sh" ]; then
    BIND_INVOKER="cap_workflow_sh"
    return 0
  fi
  BIND_SKIP_REASON="neither cap on PATH nor scripts/cap-workflow.sh found"
  return 1
}

run_bind() {
  local workflow_id="$1"
  echo "Step: cap workflow bind ${workflow_id}"
  if [ -z "${BIND_INVOKER}" ]; then
    report_warn "bind invoker unavailable — bind check skipped" "${BIND_SKIP_REASON}"
    return 0
  fi
  local out
  case "${BIND_INVOKER}" in
    cap_path)
      out="$(cap workflow bind "${workflow_id}" 2>&1)"
      ;;
    cap_workflow_sh)
      out="$(bash "${REPO_ROOT}/scripts/cap-workflow.sh" bind "${workflow_id}" 2>&1)"
      ;;
  esac
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${workflow_id} bind failed" "rc=${rc}"
    echo "${out}" | head -20 | sed 's/^/    /'
    return 1
  fi
  # The canonical positive signal is the literal `binding_status: ready` line
  # in the bind report. We additionally require required_unresolved=0 in the
  # summary to guard against future bind report shapes that drop binding_status.
  if ! printf '%s' "${out}" | grep -qE "^binding_status: ready[[:space:]]*$"; then
    report_fail "${workflow_id} binding_status not ready"
    printf '%s' "${out}" | grep -E "^binding_status:|^summary:" | head -2 | sed 's/^/    /'
    return 1
  fi
  if ! printf '%s' "${out}" | grep -qE "required_unresolved=0"; then
    report_fail "${workflow_id} has required_unresolved>0"
    printf '%s' "${out}" | grep -E "^summary:" | head -1 | sed 's/^/    /'
    return 1
  fi
  if printf '%s' "${out}" | grep -qE "=> (blocked_by_constitution|required_unresolved|incompatible)"; then
    report_fail "${workflow_id} has at least one step with blocked status"
    printf '%s' "${out}" | grep -E "=> (blocked_by_constitution|required_unresolved|incompatible)" | head -5 | sed 's/^/    /'
    return 1
  fi
  report_pass "${workflow_id} bind ready (via ${BIND_INVOKER})"
}

run_fixture() {
  local script_path="$1"
  local label="$2"
  echo "Step: ${label}"
  if [ ! -x "${script_path}" ]; then
    report_fail "${label} not executable" "${script_path}"
    return 1
  fi
  local out
  out="$(bash "${script_path}" 2>&1)"
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${label} returned non-zero" "rc=${rc}"
    printf '%s' "${out}" | tail -10 | sed 's/^/    /'
    return 1
  fi
  if ! printf '%s' "${out}" | grep -qE "[0-9]+ passed, 0 failed"; then
    report_fail "${label} did not report all-pass summary"
    printf '%s' "${out}" | tail -3 | sed 's/^/    /'
    return 1
  fi
  local summary
  summary="$(printf '%s' "${out}" | grep -E "[0-9]+ passed" | tail -1)"
  report_pass "${label}: ${summary}"
}

echo "================================================================"
echo "  CAP per-stage workflow smoke"
echo "  repo: ${REPO_ROOT}"
echo "================================================================"

resolve_bind_invoker || true
case "${BIND_INVOKER}" in
  cap_path) echo "  bind invoker: cap (on PATH)" ;;
  cap_workflow_sh) echo "  bind invoker: scripts/cap-workflow.sh (in-repo fallback)" ;;
  "") echo "  bind invoker: <unavailable> — ${BIND_SKIP_REASON}" ;;
esac
echo ""

run_bind "project-spec-pipeline"
run_bind "project-implementation-pipeline"
run_bind "project-qa-pipeline"
run_fixture "${REPO_ROOT}/tests/scripts/test-persist-task-constitution.sh" "persist-task-constitution unit smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-emit-handoff-ticket.sh" "emit-handoff-ticket unit smoke"
run_fixture "${REPO_ROOT}/tests/e2e/test-project-spec-pipeline-deterministic.sh" "spec-pipeline deterministic e2e"
run_fixture "${REPO_ROOT}/tests/e2e/test-ticket-consumption.sh" "ticket consumption e2e"

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
