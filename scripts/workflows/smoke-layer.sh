#!/usr/bin/env bash
# Focused smoke slices for local iteration. Full release gate remains
# scripts/workflows/smoke-per-stage.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_HOME_OWNER=0

if [ -z "${CAP_HOME:-}" ]; then
  CAP_HOME="$(mktemp -d -t cap-smoke-layer.XXXXXX)"
  export CAP_HOME
  CAP_HOME_OWNER=1
fi
trap '[ "${CAP_HOME_OWNER}" -eq 1 ] && rm -rf "${CAP_HOME}"' EXIT

pass_count=0
fail_count=0
warn_count=0
BIND_INVOKER=""

usage() {
  cat <<'EOF'
Usage: scripts/workflows/smoke-layer.sh <contracts|runtime|project|orchestration|e2e|promote|replay|full>
EOF
}

pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; fail_count=$((fail_count + 1)); }
warn() { echo "  WARN: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; warn_count=$((warn_count + 1)); }
label_for() { basename "$1" .sh | sed 's/^test-//; s/-/ /g'; }

resolve_bind_invoker() {
  command -v cap >/dev/null 2>&1 && { BIND_INVOKER="cap"; return; }
  [ -f "${REPO_ROOT}/scripts/cap-workflow.sh" ] && BIND_INVOKER="cap_workflow_sh"
}

run_bind() {
  local workflow_id="$1" out rc
  echo "Step: cap workflow bind ${workflow_id}"
  case "${BIND_INVOKER}" in
    cap) out="$(cap workflow bind "${workflow_id}" 2>&1)" ;;
    cap_workflow_sh) out="$(bash "${REPO_ROOT}/scripts/cap-workflow.sh" bind "${workflow_id}" 2>&1)" ;;
    *) warn "${workflow_id} bind skipped" "no cap or cap-workflow.sh"; return ;;
  esac
  rc=$?
  if [ ${rc} -ne 0 ]; then
    fail "${workflow_id} bind failed" "rc=${rc}"
    echo "${out}" | head -20 | sed 's/^/    /'
    return
  fi
  if grep -qE "^binding_status: ready[[:space:]]*$" <<<"${out}" && grep -qE "required_unresolved=0" <<<"${out}"; then
    pass "${workflow_id} bind ready (via ${BIND_INVOKER})"
  else
    fail "${workflow_id} bind not ready"
    awk '/^binding_status:|^summary:/ { print; if (++n == 2) exit }' <<<"${out}" | sed 's/^/    /'
  fi
}

run_fixture() {
  local rel_path="$1" path="${REPO_ROOT}/${1}" label out rc summary
  label="$(label_for "${rel_path}")"
  echo "Step: ${label}"
  if [ ! -x "${path}" ]; then
    fail "${label} not executable" "${path}"
    return
  fi
  out="$(bash "${path}" 2>&1)"
  rc=$?
  if [ ${rc} -ne 0 ]; then
    fail "${label} returned non-zero" "rc=${rc}"
    printf '%s' "${out}" | tail -10 | sed 's/^/    /'
    return
  fi
  summary="$(printf '%s' "${out}" | grep -E "[0-9]+ passed, 0 failed" | tail -1)"
  [ -n "${summary}" ] && pass "${label}: ${summary}" || {
    fail "${label} did not report all-pass summary"
    printf '%s' "${out}" | tail -3 | sed 's/^/    /'
  }
}

suite_items() {
  case "$1" in
    contracts) cat <<'EOF'
fixture tests/scripts/test-capability-graph-schema.sh
fixture tests/scripts/test-compiled-workflow-schema.sh
fixture tests/scripts/test-binding-report-schema.sh
fixture tests/scripts/test-supervisor-orchestration-schema.sh
fixture tests/scripts/test-workflow-result-schema.sh
fixture tests/scripts/test-gate-result-schema.sh
fixture tests/scripts/test-replay-verdict-schema.sh
EOF
      ;;
    runtime) cat <<'EOF'
fixture tests/scripts/test-compiled-workflow-validation-hook.sh
fixture tests/scripts/test-binding-report-validation-hook.sh
fixture tests/scripts/test-workflow-policy-gates.sh
fixture tests/scripts/test-agent-session-runner.sh
fixture tests/scripts/test-provider-adapters.sh
fixture tests/scripts/test-cap-session-inspect.sh
fixture tests/scripts/test-cap-session-analyze.sh
fixture tests/scripts/test-cap-artifact-inspect.sh
fixture tests/scripts/test-handoff-route-back.sh
fixture tests/scripts/test-gate-result-consumer.sh
fixture tests/scripts/test-binder-phase5-attachment.sh
fixture tests/scripts/test-step-runtime-attached-prompts.sh
fixture tests/scripts/test-binder-project-context-origin.sh
fixture tests/scripts/test-validate-inputs-intrinsic-vs-registry.sh
EOF
      ;;
    project) cat <<'EOF'
fixture tests/scripts/test-project-id-resolver.sh
fixture tests/scripts/test-identity-ledger-schema.sh
fixture tests/scripts/test-storage-health.sh
fixture tests/scripts/test-project-init.sh
fixture tests/scripts/test-project-status.sh
fixture tests/scripts/test-project-doctor.sh
fixture tests/scripts/test-cap-project-constitution.sh
fixture tests/scripts/test-cap-task-constitution.sh
EOF
      ;;
    orchestration) cat <<'EOF'
bind supervisor-orchestration
fixture tests/scripts/test-supervisor-envelope-helper.sh
fixture tests/scripts/test-validate-supervisor-envelope-exit-code.sh
fixture tests/scripts/test-orchestration-snapshot.sh
fixture tests/scripts/test-compile-task-from-envelope.sh
fixture tests/e2e/test-supervisor-orchestration-release-gate.sh
EOF
      ;;
    e2e) cat <<'EOF'
fixture tests/e2e/test-cap-project-constitution-prompt.sh
fixture tests/e2e/test-cap-task-constitution-equivalence.sh
fixture tests/e2e/test-project-spec-pipeline-deterministic.sh
fixture tests/e2e/test-ticket-consumption.sh
fixture tests/e2e/test-cap-replay-verify.sh
EOF
      ;;
    promote) cat <<'EOF'
fixture tests/scripts/test-promote-candidate-producer.sh
fixture tests/scripts/test-cap-promote-inspect.sh
fixture tests/scripts/test-cap-promote-project-constitution.sh
fixture tests/scripts/test-cap-promote-workflow.sh
EOF
      ;;
    replay) cat <<'EOF'
fixture tests/scripts/test-agent-skills-snapshot.sh
fixture tests/scripts/test-replay-verifier.sh
fixture tests/scripts/test-project-skills-snapshot.sh
fixture tests/scripts/test-replay-verifier-dual-axis.sh
fixture tests/scripts/test-h3-input-snapshots.sh
EOF
      ;;
  esac
}

run_suite() {
  local kind target
  while read -r kind target; do
    [ -z "${kind}" ] && continue
    [ "${kind}" = "bind" ] && run_bind "${target}" || run_fixture "${target}"
  done < <(suite_items "$1")
}

suite="${1:-}"
case "${suite}" in
  -h|--help|"") usage; exit 0 ;;
  full) exec bash "${REPO_ROOT}/scripts/workflows/smoke-per-stage.sh" ;;
  contracts|runtime|project|orchestration|e2e|promote|replay) ;;
  *) usage >&2; echo "Unknown smoke suite: ${suite}" >&2; exit 2 ;;
esac

resolve_bind_invoker
echo "CAP smoke layer: ${suite}"
echo "repo: ${REPO_ROOT}"
echo "CAP_HOME: ${CAP_HOME}"
run_suite "${suite}"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"

[ ${fail_count} -eq 0 ]
