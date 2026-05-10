#!/usr/bin/env bash
#
# smoke-layer.sh - Focused smoke slices for local iteration.
#
# This wrapper does not replace smoke-per-stage.sh. Use smoke-per-stage.sh as
# the full release gate; use these slices when changing one runtime area.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SMOKE_LAYER_OWNS_CAP_HOME=0
if [ -z "${CAP_HOME:-}" ]; then
  CAP_HOME="$(mktemp -d -t cap-smoke-layer.XXXXXX)"
  export CAP_HOME
  SMOKE_LAYER_OWNS_CAP_HOME=1
fi

cleanup() {
  if [ "${SMOKE_LAYER_OWNS_CAP_HOME}" -eq 1 ]; then
    rm -rf "${CAP_HOME}"
  fi
}
trap cleanup EXIT

pass_count=0
fail_count=0
warn_count=0

usage() {
  cat <<'EOF'
Usage:
  scripts/workflows/smoke-layer.sh <suite>

Suites:
  contracts      JSON schema and validation contract fixtures
  runtime        workflow execution, sessions, gates, artifacts
  project        project identity, storage, constitution CLI
  orchestration  supervisor envelope and compile-from-envelope path
  e2e            deterministic e2e fixtures
  promote        promote surface fixtures
  replay         replay / drift harness fixtures
  full           delegate to smoke-per-stage.sh

Examples:
  scripts/workflows/smoke-layer.sh contracts
  scripts/workflows/smoke-layer.sh orchestration
  scripts/workflows/smoke-layer.sh full
EOF
}

report_pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
report_fail() { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; fail_count=$((fail_count + 1)); }
report_warn() { echo "  WARN: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; warn_count=$((warn_count + 1)); }

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
  if ! grep -qE "[0-9]+ passed, 0 failed" <<<"${out}"; then
    report_fail "${label} did not report all-pass summary"
    printf '%s' "${out}" | tail -3 | sed 's/^/    /'
    return 1
  fi
  local summary
  summary="$(printf '%s' "${out}" | grep -E "[0-9]+ passed" | tail -1)"
  report_pass "${label}: ${summary}"
}

resolve_bind_invoker() {
  if command -v cap >/dev/null 2>&1; then
    BIND_INVOKER="cap"
    return 0
  fi
  if [ -f "${REPO_ROOT}/scripts/cap-workflow.sh" ]; then
    BIND_INVOKER="cap_workflow_sh"
    return 0
  fi
  BIND_INVOKER=""
  return 1
}

run_bind() {
  local workflow_id="$1"
  echo "Step: cap workflow bind ${workflow_id}"
  local out
  case "${BIND_INVOKER}" in
    cap)
      out="$(cap workflow bind "${workflow_id}" 2>&1)"
      ;;
    cap_workflow_sh)
      out="$(bash "${REPO_ROOT}/scripts/cap-workflow.sh" bind "${workflow_id}" 2>&1)"
      ;;
    *)
      report_warn "${workflow_id} bind skipped" "neither cap on PATH nor scripts/cap-workflow.sh found"
      return 0
      ;;
  esac
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${workflow_id} bind failed" "rc=${rc}"
    echo "${out}" | head -20 | sed 's/^/    /'
    return 1
  fi
  if ! grep -qE "^binding_status: ready[[:space:]]*$" <<<"${out}" || ! grep -qE "required_unresolved=0" <<<"${out}"; then
    report_fail "${workflow_id} bind not ready"
    awk '/^binding_status:|^summary:/ { print; if (++n == 2) exit }' <<<"${out}" | sed 's/^/    /'
    return 1
  fi
  report_pass "${workflow_id} bind ready (via ${BIND_INVOKER})"
}

suite_contracts() {
  run_fixture "${REPO_ROOT}/tests/scripts/test-capability-graph-schema.sh" "capability graph schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-compiled-workflow-schema.sh" "compiled workflow schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-binding-report-schema.sh" "binding report schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-supervisor-orchestration-schema.sh" "supervisor orchestration schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-workflow-result-schema.sh" "workflow result schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-gate-result-schema.sh" "gate result schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-replay-verdict-schema.sh" "replay verdict schema"
}

suite_runtime() {
  run_fixture "${REPO_ROOT}/tests/scripts/test-compiled-workflow-validation-hook.sh" "compiled workflow validation hook"
  run_fixture "${REPO_ROOT}/tests/scripts/test-binding-report-validation-hook.sh" "binding report validation hook"
  run_fixture "${REPO_ROOT}/tests/scripts/test-workflow-policy-gates.sh" "workflow policy gates"
  run_fixture "${REPO_ROOT}/tests/scripts/test-agent-session-runner.sh" "agent session runner"
  run_fixture "${REPO_ROOT}/tests/scripts/test-provider-adapters.sh" "provider adapters"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-session-inspect.sh" "cap session inspect"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-session-analyze.sh" "cap session analyze"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-artifact-inspect.sh" "artifact inspect"
  run_fixture "${REPO_ROOT}/tests/scripts/test-handoff-route-back.sh" "handoff route back"
  run_fixture "${REPO_ROOT}/tests/scripts/test-gate-result-consumer.sh" "gate result consumer"
}

suite_project() {
  run_fixture "${REPO_ROOT}/tests/scripts/test-project-id-resolver.sh" "project id resolver"
  run_fixture "${REPO_ROOT}/tests/scripts/test-identity-ledger-schema.sh" "identity ledger schema"
  run_fixture "${REPO_ROOT}/tests/scripts/test-storage-health.sh" "storage health"
  run_fixture "${REPO_ROOT}/tests/scripts/test-project-init.sh" "project init"
  run_fixture "${REPO_ROOT}/tests/scripts/test-project-status.sh" "project status"
  run_fixture "${REPO_ROOT}/tests/scripts/test-project-doctor.sh" "project doctor"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-project-constitution.sh" "project constitution"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-task-constitution.sh" "task constitution"
}

suite_orchestration() {
  run_bind "supervisor-orchestration"
  run_fixture "${REPO_ROOT}/tests/scripts/test-supervisor-envelope-helper.sh" "supervisor envelope helper"
  run_fixture "${REPO_ROOT}/tests/scripts/test-validate-supervisor-envelope-exit-code.sh" "validate supervisor envelope"
  run_fixture "${REPO_ROOT}/tests/scripts/test-orchestration-snapshot.sh" "orchestration snapshot"
  run_fixture "${REPO_ROOT}/tests/scripts/test-compile-task-from-envelope.sh" "compile task from envelope"
  run_fixture "${REPO_ROOT}/tests/e2e/test-supervisor-orchestration-release-gate.sh" "supervisor orchestration release gate"
}

suite_e2e() {
  run_fixture "${REPO_ROOT}/tests/e2e/test-cap-project-constitution-prompt.sh" "project constitution prompt e2e"
  run_fixture "${REPO_ROOT}/tests/e2e/test-cap-task-constitution-equivalence.sh" "task constitution equivalence e2e"
  run_fixture "${REPO_ROOT}/tests/e2e/test-project-spec-pipeline-deterministic.sh" "project spec pipeline deterministic e2e"
  run_fixture "${REPO_ROOT}/tests/e2e/test-ticket-consumption.sh" "ticket consumption e2e"
  run_fixture "${REPO_ROOT}/tests/e2e/test-cap-replay-verify.sh" "cap replay verify e2e"
}

suite_promote() {
  run_fixture "${REPO_ROOT}/tests/scripts/test-promote-candidate-producer.sh" "promote candidate producer"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-promote-inspect.sh" "cap promote inspect"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-promote-project-constitution.sh" "cap promote project constitution"
  run_fixture "${REPO_ROOT}/tests/scripts/test-cap-promote-workflow.sh" "cap promote workflow"
}

suite_replay() {
  run_fixture "${REPO_ROOT}/tests/scripts/test-agent-skills-snapshot.sh" "agent skills snapshot"
  run_fixture "${REPO_ROOT}/tests/scripts/test-replay-verifier.sh" "replay verifier"
  run_fixture "${REPO_ROOT}/tests/scripts/test-project-skills-snapshot.sh" "project skills snapshot"
  run_fixture "${REPO_ROOT}/tests/scripts/test-replay-verifier-dual-axis.sh" "replay verifier dual axis"
  run_fixture "${REPO_ROOT}/tests/scripts/test-h3-input-snapshots.sh" "H3 input snapshots"
}

suite="${1:-}"
case "${suite}" in
  -h|--help|"")
    usage
    exit 0
    ;;
  full)
    exec bash "${REPO_ROOT}/scripts/workflows/smoke-per-stage.sh"
    ;;
  contracts|runtime|project|orchestration|e2e|promote|replay)
    ;;
  *)
    usage >&2
    echo "" >&2
    echo "Unknown smoke suite: ${suite}" >&2
    exit 2
    ;;
esac

resolve_bind_invoker || true

echo "================================================================"
echo "  CAP smoke layer: ${suite}"
echo "  repo: ${REPO_ROOT}"
echo "  CAP_HOME: ${CAP_HOME}"
echo "================================================================"

"suite_${suite}"

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
