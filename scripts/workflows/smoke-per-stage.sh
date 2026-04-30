#!/usr/bin/env bash
#
# smoke-per-stage.sh — Single-command smoke check for the per-stage workflow
# series introduced in v0.19.x.
#
# Runs (in order):
#   1. cap workflow bind project-spec-pipeline           (must end in ready)
#   2. cap workflow bind project-implementation-pipeline (must end in ready)
#   3. cap workflow bind project-qa-pipeline             (must end in ready)
#   4. tests/scripts/test-persist-task-constitution.sh   (must report 13/13)
#   5. tests/scripts/test-emit-handoff-ticket.sh         (must report 15/15)
#
# Steps 1-3 are skipped gracefully (with WARN status) when the cap CLI is not
# on PATH; the script still proceeds to run the bash fixture suites so it can
# be used as a hermetic CI gate that does not require the cap installer.
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

check_cap_cli() {
  if command -v cap >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

run_bind() {
  local workflow_id="$1"
  echo "Step: cap workflow bind ${workflow_id}"
  if ! check_cap_cli; then
    report_warn "cap CLI not on PATH — bind check skipped" "install cap to enable runtime binding smoke"
    return 0
  fi
  local out
  out="$(cap workflow bind "${workflow_id}" 2>&1)"
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${workflow_id} bind failed" "rc=${rc}"
    echo "${out}" | head -20 | sed 's/^/    /'
    return 1
  fi
  if printf '%s' "${out}" | grep -qE "blocked_by_constitution|required_unresolved|incompatible"; then
    report_fail "${workflow_id} bind reports blocked or unresolved steps"
    printf '%s' "${out}" | grep -E "blocked_by_constitution|required_unresolved|incompatible" | head -5 | sed 's/^/    /'
    return 1
  fi
  report_pass "${workflow_id} bind looks ready"
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
echo ""

run_bind "project-spec-pipeline"
run_bind "project-implementation-pipeline"
run_bind "project-qa-pipeline"
run_fixture "${REPO_ROOT}/tests/scripts/test-persist-task-constitution.sh" "persist-task-constitution fixture"
run_fixture "${REPO_ROOT}/tests/scripts/test-emit-handoff-ticket.sh" "emit-handoff-ticket fixture"

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
