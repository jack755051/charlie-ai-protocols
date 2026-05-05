#!/usr/bin/env bash
#
# smoke-per-stage.sh — Single-command smoke check for the per-stage workflow
# series introduced in v0.19.x.
#
# Runs (in order):
#   1. cap workflow bind project-spec-pipeline                   (must end in ready)
#   2. cap workflow bind project-implementation-pipeline         (must end in ready)
#   3. cap workflow bind project-qa-pipeline                     (must end in ready)
#   3a. cap workflow bind supervisor-orchestration               (P3 #5-c, must end in ready)
#   4. tests/scripts/test-persist-task-constitution.sh           (must report all-pass)
#   5. tests/scripts/test-emit-handoff-ticket.sh                 (must report all-pass)
#   6. tests/scripts/test-design-source-resolution.sh            (must report all-pass)
#   7. tests/scripts/test-cap-workflow-design-package-forwarding.sh (must report all-pass)
#   8. tests/scripts/test-design-source-ingest.sh                (must report all-pass)
#   9. tests/scripts/test-provider-parity-check.sh               (must report all-pass)
#  10. tests/scripts/test-validate-constitution-exit-code.sh     (P0a exit 41 gate)
#  11. tests/scripts/test-bootstrap-constitution-defaults-exit-code.sh (P0a exit 41 gate)
#  12. tests/scripts/test-persist-constitution-exit-code.sh      (P0a exit 41 gate)
#  13. tests/scripts/test-load-constitution-reconcile-inputs-exit-code.sh (P0a exit 41 gate)
#  14. tests/scripts/test-capability-graph-schema.sh             (P0 #1 schema gate)
#  15. tests/scripts/test-compiled-workflow-schema.sh            (P0 #2 schema gate)
#  16. tests/scripts/test-binding-report-schema.sh               (P0 #3 schema gate)
#  17. tests/scripts/test-supervisor-orchestration-schema.sh     (P0 #4 schema gate, forward contract)
#  18. tests/scripts/test-workflow-result-schema.sh              (P0 #5 schema gate, normalized contract)
#  19. tests/scripts/test-gate-result-schema.sh                  (P0 #6 schema gate, forward contract)
#  20. tests/scripts/test-project-id-resolver.sh                 (P1 #1 + #2 + #3 resolver + ledger gate)
#  21. tests/scripts/test-identity-ledger-schema.sh              (P1 #3 ledger schema gate, normalized contract)
#  22. tests/scripts/test-storage-health.sh                      (P1 #4 storage health-check core)
#  23. tests/scripts/test-project-init.sh                        (P1 #6 cap project init)
#  24. tests/scripts/test-project-status.sh                      (P1 #5 cap project status)
#  25. tests/scripts/test-project-doctor.sh                      (P1 #7 cap project doctor)
#  26. tests/scripts/test-cap-project-constitution.sh            (P2 #2 + #5 cap project constitution: dry-run + from-file + validation + promote)
#  27. tests/scripts/test-cap-task-constitution.sh               (P2 #6 cap task constitution alias + cap workflow constitution deprecation)
#  28. tests/e2e/test-cap-project-constitution-prompt.sh         (P2 #8 prompt-mode e2e via CAP_PROJECT_CONSTITUTION_WORKFLOW_STUB; deterministic, no AI)
#  29. tests/e2e/test-cap-task-constitution-equivalence.sh       (P2 #8 cap task / cap workflow constitution byte-equal stdout + canonical JSON parity)
#  30. tests/scripts/test-supervisor-envelope-helper.sh          (P3 #3 supervisor envelope pure helpers: extract / validate / drift)
#  31. tests/scripts/test-validate-supervisor-envelope-exit-code.sh (P3 #4 schema-class executor exit-41 gate: missing artifact / extract fail / schema fail / drift)
#  32. tests/scripts/test-orchestration-snapshot.sh              (P3 #5-a four-part snapshot writer: happy + extract/schema/drift fails still land + invalid stamp + pure helper)
#  33. tests/scripts/test-compile-task-from-envelope.sh          (P3 #5-b envelope-driven compile entry: legacy untouched + hint round-trip + drift / schema raises)
#  34. tests/e2e/test-supervisor-orchestration-release-gate.sh  (P3 #8 release gate: end-to-end envelope flow across all P3 modules + binding ready)
#  35. tests/e2e/test-project-spec-pipeline-deterministic.sh     (must report all-pass)
#  36. tests/e2e/test-ticket-consumption.sh                      (must report all-pass)
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
run_bind "supervisor-orchestration"
run_fixture "${REPO_ROOT}/tests/scripts/test-persist-task-constitution.sh" "persist-task-constitution unit smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-emit-handoff-ticket.sh" "emit-handoff-ticket unit smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-design-source-resolution.sh" "design source resolution unit smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-workflow-design-package-forwarding.sh" "cap-workflow design-package forwarding smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-design-source-ingest.sh" "design-source ingest smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-provider-parity-check.sh" "provider parity checker smoke"
run_fixture "${REPO_ROOT}/tests/scripts/test-validate-constitution-exit-code.sh" "validate-constitution exit-41 gate (P0a)"
run_fixture "${REPO_ROOT}/tests/scripts/test-bootstrap-constitution-defaults-exit-code.sh" "bootstrap-constitution-defaults exit-41 gate (P0a)"
run_fixture "${REPO_ROOT}/tests/scripts/test-persist-constitution-exit-code.sh" "persist-constitution exit-41 gate (P0a)"
run_fixture "${REPO_ROOT}/tests/scripts/test-load-constitution-reconcile-inputs-exit-code.sh" "load-constitution-reconcile-inputs exit-41 gate (P0a)"
run_fixture "${REPO_ROOT}/tests/scripts/test-capability-graph-schema.sh" "capability-graph schema gate (P0 #1)"
run_fixture "${REPO_ROOT}/tests/scripts/test-compiled-workflow-schema.sh" "compiled-workflow schema gate (P0 #2)"
run_fixture "${REPO_ROOT}/tests/scripts/test-compiled-workflow-validation-hook.sh" "compiled-workflow validation hook (P4 #1)"
run_fixture "${REPO_ROOT}/tests/scripts/test-binding-report-validation-hook.sh" "binding-report validation hook (P4 #2)"
run_fixture "${REPO_ROOT}/tests/scripts/test-compiled-workflow-normalization.sh" "compiled-workflow normalization (P4 #4)"
run_fixture "${REPO_ROOT}/tests/scripts/test-workflow-policy-gates.sh" "workflow policy gates (P4 #6-#9)"
run_fixture "${REPO_ROOT}/tests/scripts/test-preflight-report.sh" "preflight report (P4 #10)"
run_fixture "${REPO_ROOT}/tests/scripts/test-workflow-dry-run-inspection.sh" "workflow dry-run inspection (P4 #11)"
run_fixture "${REPO_ROOT}/tests/scripts/test-agent-session-runner.sh" "agent-session-runner baseline (P5 #1-#3)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-session-inspect.sh" "cap session inspect (P5 #10)"
run_fixture "${REPO_ROOT}/tests/scripts/test-provider-adapters.sh" "provider adapters (P5 #3 codex + #4 claude)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-session-analyze.sh" "cap session analyze (token/time)"
run_fixture "${REPO_ROOT}/tests/scripts/test-shell-prompt-snapshot.sh" "shell executor prompt snapshot wiring"
run_fixture "${REPO_ROOT}/tests/scripts/test-step-failure-detail.sh" "step failure detail extractor"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-artifact-inspect.sh" "cap artifact registry inspect (P6 #1+#2)"
run_fixture "${REPO_ROOT}/tests/scripts/test-capability-validator.sh" "capability validator registry (P6 #5+#6+#7)"
run_fixture "${REPO_ROOT}/tests/scripts/test-required-output-enforcement.sh" "required-output enforcement opt-in gate (P6 #4)"
run_fixture "${REPO_ROOT}/tests/scripts/test-manage-cap-alias-defaults.sh" "installer native CLI isolation (P0b)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-session-native-fallback.sh" "cap session native fallback outside project (P0b)"
run_fixture "${REPO_ROOT}/tests/scripts/test-mapper-global-isolation.sh" "mapper global rule isolation (P0b)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-config-namespace-resolver.sh" "config namespace resolver dual-path (P0c batch 1)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-project-migrate-config.sh" "cap project migrate-config (P0c batch 2)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-project-init-namespace.sh" "cap project init writes new namespace (P0c batch 2.5)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-config-namespace-readers.sh" "skills / agents / constitution readers dual-path (P0c batch 2.5)"
run_fixture "${REPO_ROOT}/tests/scripts/test-handoff-schema-gate.sh" "handoff schema pre-dispatch opt-in gate (P6 #3)"
run_fixture "${REPO_ROOT}/tests/scripts/test-handoff-route-back.sh" "handoff route_back_to opt-in control flow (P6 #8)"
run_fixture "${REPO_ROOT}/tests/scripts/test-binding-report-schema.sh" "binding-report schema gate (P0 #3)"
run_fixture "${REPO_ROOT}/tests/scripts/test-supervisor-orchestration-schema.sh" "supervisor-orchestration schema gate (P0 #4, forward contract)"
run_fixture "${REPO_ROOT}/tests/scripts/test-workflow-result-schema.sh" "workflow-result schema gate (P0 #5, normalized contract)"
run_fixture "${REPO_ROOT}/tests/scripts/test-gate-result-schema.sh" "gate-result schema gate (P0 #6, forward contract)"
run_fixture "${REPO_ROOT}/tests/scripts/test-project-id-resolver.sh" "project-id resolver + ledger gate (P1 #1/#2/#3)"
run_fixture "${REPO_ROOT}/tests/scripts/test-identity-ledger-schema.sh" "identity-ledger schema gate (P1 #3, normalized contract)"
run_fixture "${REPO_ROOT}/tests/scripts/test-storage-health.sh" "storage health-check core (P1 #4)"
run_fixture "${REPO_ROOT}/tests/scripts/test-project-init.sh" "cap project init (P1 #6)"
run_fixture "${REPO_ROOT}/tests/scripts/test-project-status.sh" "cap project status (P1 #5)"
run_fixture "${REPO_ROOT}/tests/scripts/test-project-doctor.sh" "cap project doctor (P1 #7)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-project-constitution.sh" "cap project constitution (P2 #2 + #5: dry-run + from-file + validation + promote)"
run_fixture "${REPO_ROOT}/tests/scripts/test-cap-task-constitution.sh" "cap task constitution alias + cap workflow constitution deprecation (P2 #6)"
run_fixture "${REPO_ROOT}/tests/e2e/test-cap-project-constitution-prompt.sh" "cap project constitution prompt-mode e2e (P2 #8, stub-driven)"
run_fixture "${REPO_ROOT}/tests/e2e/test-cap-task-constitution-equivalence.sh" "cap task constitution alias equivalence e2e (P2 #8)"
run_fixture "${REPO_ROOT}/tests/scripts/test-supervisor-envelope-helper.sh" "supervisor envelope helper smoke (P3 #3: extract / validate / drift)"
run_fixture "${REPO_ROOT}/tests/scripts/test-validate-supervisor-envelope-exit-code.sh" "validate-supervisor-envelope exit-41 gate (P3 #4)"
run_fixture "${REPO_ROOT}/tests/scripts/test-orchestration-snapshot.sh" "orchestration four-part snapshot writer (P3 #5-a)"
run_fixture "${REPO_ROOT}/tests/scripts/test-compile-task-from-envelope.sh" "compile_task_from_envelope (P3 #5-b)"
run_fixture "${REPO_ROOT}/tests/e2e/test-supervisor-orchestration-release-gate.sh" "supervisor orchestration release-gate e2e (P3 #8)"
run_fixture "${REPO_ROOT}/tests/e2e/test-project-spec-pipeline-deterministic.sh" "spec-pipeline deterministic e2e"
run_fixture "${REPO_ROOT}/tests/e2e/test-ticket-consumption.sh" "ticket consumption e2e"

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
