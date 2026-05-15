#!/usr/bin/env bash
#
# smoke-per-stage.sh - Full CAP release-gate smoke.
#
# This is the canonical full smoke gate. The executable step list lives in
# smoke_steps(); use --list to print it. Keep smoke-layer.sh for focused local
# slices and this script for full pre-release confidence.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

pass_count=0
fail_count=0
warn_count=0
BIND_INVOKER=""
BIND_SKIP_REASON=""

usage() {
  cat <<'EOF'
Usage:
  scripts/workflows/smoke-per-stage.sh [--list]

Options:
  --list    Print the full smoke step list without executing it.

Exit codes:
  0  all checks passed, or --list completed
  1  at least one check failed
  2  invalid arguments
EOF
}

report_pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
report_fail() { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; fail_count=$((fail_count + 1)); }
report_warn() { echo "  WARN: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; warn_count=$((warn_count + 1)); }

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
    report_warn "bind invoker unavailable - bind check skipped" "${BIND_SKIP_REASON}"
    return 0
  fi

  local out rc
  case "${BIND_INVOKER}" in
    cap_path) out="$(cap workflow bind "${workflow_id}" 2>&1)" ;;
    cap_workflow_sh) out="$(bash "${REPO_ROOT}/scripts/cap-workflow.sh" bind "${workflow_id}" 2>&1)" ;;
  esac
  rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${workflow_id} bind failed" "rc=${rc}"
    echo "${out}" | head -20 | sed 's/^/    /'
    return 1
  fi
  if ! grep -qE "^binding_status: ready[[:space:]]*$" <<<"${out}"; then
    report_fail "${workflow_id} binding_status not ready"
    awk '/^binding_status:|^summary:/ { print; if (++n == 2) exit }' <<<"${out}" | sed 's/^/    /'
    return 1
  fi
  if ! grep -qE "required_unresolved=0" <<<"${out}"; then
    report_fail "${workflow_id} has required_unresolved>0"
    awk '/^summary:/ { print; exit }' <<<"${out}" | sed 's/^/    /'
    return 1
  fi
  if grep -qE "=> (blocked_by_constitution|required_unresolved|incompatible)" <<<"${out}"; then
    report_fail "${workflow_id} has at least one step with blocked status"
    awk '/=> (blocked_by_constitution|required_unresolved|incompatible)/ { print; if (++n == 5) exit }' <<<"${out}" | sed 's/^/    /'
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

  local out rc summary
  out="$(bash "${script_path}" 2>&1)"
  rc=$?
  if [ ${rc} -ne 0 ]; then
    report_fail "${label} returned non-zero" "rc=${rc}"
    printf '%s' "${out}" | tail -10 | sed 's/^/    /'
    return 1
  fi
  summary="$(printf '%s' "${out}" | grep -E "[0-9]+ passed, 0 failed" | tail -1)"
  if [ -z "${summary}" ]; then
    report_fail "${label} did not report all-pass summary"
    printf '%s' "${out}" | tail -3 | sed 's/^/    /'
    return 1
  fi
  report_pass "${label}: ${summary}"
}

smoke_steps() {
  cat <<'EOF'
bind|project-spec-pipeline|project-spec-pipeline bind ready
bind|project-implementation-pipeline|project-implementation-pipeline bind ready
bind|project-qa-pipeline|project-qa-pipeline bind ready
bind|supervisor-orchestration|supervisor-orchestration bind ready
fixture|tests/scripts/test-cap-entry-help-surface.sh|cap-entry help surface
fixture|tests/scripts/test-cap-entry-unknown-command.sh|cap-entry unknown command catch
fixture|tests/scripts/test-cap-entry-shortcuts.sh|cap-entry namespace shortcuts
fixture|tests/scripts/test-cap-workflow-static-outside-project.sh|cap workflow static list outside project
fixture|tests/scripts/test-cap-provider-doctor.sh|cap provider doctor read-only inspector
fixture|tests/scripts/test-cap-workflow-cli-fail-fast.sh|cap workflow run --cli fail-fast guard
fixture|tests/scripts/test-persist-task-constitution.sh|persist-task-constitution unit smoke
fixture|tests/scripts/test-emit-handoff-ticket.sh|emit-handoff-ticket unit smoke
fixture|tests/scripts/test-design-source-resolution.sh|design source resolution unit smoke
fixture|tests/scripts/test-cap-workflow-design-package-forwarding.sh|cap-workflow design-package forwarding smoke
fixture|tests/scripts/test-design-source-ingest.sh|design-source ingest smoke
fixture|tests/scripts/test-validate-constitution-exit-code.sh|validate-constitution exit-41 gate (P0a)
fixture|tests/scripts/test-bootstrap-constitution-defaults-exit-code.sh|bootstrap-constitution-defaults exit-41 gate (P0a)
fixture|tests/scripts/test-persist-constitution-exit-code.sh|persist-constitution exit-41 gate (P0a)
fixture|tests/scripts/test-load-constitution-reconcile-inputs-exit-code.sh|load-constitution-reconcile-inputs exit-41 gate (P0a)
fixture|tests/scripts/test-capability-graph-schema.sh|capability-graph schema gate (P0 #1)
fixture|tests/scripts/test-compiled-workflow-schema.sh|compiled-workflow schema gate (P0 #2)
fixture|tests/scripts/test-compiled-workflow-validation-hook.sh|compiled-workflow validation hook (P4 #1)
fixture|tests/scripts/test-binding-report-validation-hook.sh|binding-report validation hook (P4 #2)
fixture|tests/scripts/test-compiled-workflow-normalization.sh|compiled-workflow normalization (P4 #4)
fixture|tests/scripts/test-workflow-policy-gates.sh|workflow policy gates (P4 #6-#9)
fixture|tests/scripts/test-preflight-report.sh|preflight report (P4 #10)
fixture|tests/scripts/test-workflow-dry-run-inspection.sh|workflow dry-run inspection (P4 #11)
fixture|tests/scripts/test-agent-session-runner.sh|agent-session-runner baseline (P5 #1-#3)
fixture|tests/scripts/test-cap-session-inspect.sh|cap session inspect (P5 #10)
fixture|tests/scripts/test-provider-adapters.sh|provider adapters (P5 #3 codex + #4 claude)
fixture|tests/scripts/test-cap-session-analyze.sh|cap session analyze (token/time)
fixture|tests/scripts/test-shell-prompt-snapshot.sh|shell executor prompt snapshot wiring
fixture|tests/scripts/test-step-failure-detail.sh|step failure detail extractor
fixture|tests/scripts/test-cap-artifact-inspect.sh|cap artifact registry inspect (P6 #1+#2)
fixture|tests/scripts/test-capability-validator.sh|capability validator registry (P6 #5+#6+#7)
fixture|tests/scripts/test-required-output-enforcement.sh|required-output enforcement opt-in gate (P6 #4)
fixture|tests/scripts/test-manage-cap-alias-defaults.sh|installer native CLI isolation (P0b)
fixture|tests/scripts/test-cap-session-native-fallback.sh|cap session native fallback outside project (P0b)
fixture|tests/scripts/test-mapper-global-isolation.sh|mapper global rule isolation (P0b)
fixture|tests/scripts/test-cap-config-namespace-resolver.sh|config namespace resolver dual-path (P0c batch 1)
fixture|tests/scripts/test-cap-project-migrate-config.sh|cap project migrate-config (P0c batch 2)
fixture|tests/scripts/test-cap-project-init-namespace.sh|cap project init writes new namespace (P0c batch 2.5)
fixture|tests/scripts/test-cap-config-namespace-readers.sh|skills / agents / constitution readers dual-path (P0c batch 2.5)
fixture|tests/scripts/test-handoff-schema-gate.sh|handoff schema pre-dispatch opt-in gate (P6 #3)
fixture|tests/scripts/test-handoff-route-back.sh|handoff route_back_to opt-in control flow (P6 #8)
fixture|tests/scripts/test-binding-report-schema.sh|binding-report schema gate (P0 #3)
fixture|tests/scripts/test-supervisor-orchestration-schema.sh|supervisor-orchestration schema gate (P0 #4, forward contract)
fixture|tests/scripts/test-workflow-result-schema.sh|workflow-result schema gate (P0 #5, normalized contract)
fixture|tests/scripts/test-gate-result-schema.sh|gate-result schema gate (P0 #6, forward contract)
fixture|tests/scripts/test-validate-gate-result-cli.sh|validate-gate-result CLI contract (P8 #5)
fixture|tests/scripts/test-watcher-gate-runner.sh|watcher checkpoint runner (P8 #1)
fixture|tests/scripts/test-security-gate-runner.sh|security checkpoint runner (P8 #3)
fixture|tests/scripts/test-qa-gate-runner.sh|qa checkpoint runner (P8 #4)
fixture|tests/scripts/test-logger-gate-runner.sh|logger milestone runner (P8 #5)
fixture|tests/scripts/test-gate-result-consumer.sh|gate-result fail-route consumer (P8 #6)
fixture|tests/scripts/test-rerun-gate.sh|rerun-failed-gate consumer (P8 #8)
fixture|tests/scripts/test-project-id-resolver.sh|project-id resolver + ledger gate (P1 #1/#2/#3)
fixture|tests/scripts/test-identity-ledger-schema.sh|identity-ledger schema gate (P1 #3, normalized contract)
fixture|tests/scripts/test-storage-health.sh|storage health-check core (P1 #4)
fixture|tests/scripts/test-project-init.sh|cap project init (P1 #6)
fixture|tests/scripts/test-project-status.sh|cap project status (P1 #5)
fixture|tests/scripts/test-project-doctor.sh|cap project doctor (P1 #7)
fixture|tests/scripts/test-cap-project-constitution.sh|cap project constitution (P2 #2 + #5: dry-run + from-file + validation + promote)
fixture|tests/scripts/test-cap-task-constitution.sh|cap task constitution alias + cap workflow constitution deprecation (P2 #6)
fixture|tests/e2e/test-cap-project-constitution-prompt.sh|cap project constitution prompt-mode e2e (P2 #8, stub-driven)
fixture|tests/e2e/test-cap-task-constitution-equivalence.sh|cap task constitution alias equivalence e2e (P2 #8)
fixture|tests/scripts/test-supervisor-envelope-helper.sh|supervisor envelope helper smoke (P3 #3: extract / validate / drift)
fixture|tests/scripts/test-validate-supervisor-envelope-exit-code.sh|validate-supervisor-envelope exit-41 gate (P3 #4)
fixture|tests/scripts/test-orchestration-snapshot.sh|orchestration four-part snapshot writer (P3 #5-a)
fixture|tests/scripts/test-compile-task-from-envelope.sh|compile_task_from_envelope (P3 #5-b)
fixture|tests/e2e/test-supervisor-orchestration-release-gate.sh|supervisor orchestration release-gate e2e (P3 #8)
fixture|tests/e2e/test-project-spec-pipeline-deterministic.sh|spec-pipeline deterministic e2e
fixture|tests/e2e/test-ticket-consumption.sh|ticket consumption e2e
fixture|tests/scripts/test-promote-candidate-producer.sh|promote_candidate_producer (P10 #2.2)
fixture|tests/scripts/test-cap-promote-inspect.sh|cap promote inspect (P10 #3)
fixture|tests/scripts/test-cap-promote-project-constitution.sh|cap promote project-constitution apply / backup / validation / rollback (P10 #4 + #6)
fixture|tests/scripts/test-cap-promote-workflow.sh|cap promote workflow apply / backup / validation / rollback (P10 #5 + #6)
fixture|tests/scripts/test-skill-registry-resolver.sh|skill registry layered resolver (P9 #3)
fixture|tests/scripts/test-skill-registry-override.sh|skill registry override contract (A0 #2: disabled / replaces)
fixture|tests/scripts/test-agent-skills-snapshot.sh|agent-skills baseline snapshot (A0 #4: dir + per-file hash)
fixture|tests/scripts/test-replay-verdict-schema.sh|replay-verdict schema gate (H1 #2)
fixture|tests/scripts/test-replay-verifier.sh|replay verifier engine + CLI (H1 #3)
fixture|tests/e2e/test-cap-replay-verify.sh|cap replay verify shell wrapper e2e (H1 #4)
fixture|tests/scripts/test-project-skills-snapshot.sh|project skills snapshot module (H2 #2)
fixture|tests/scripts/test-replay-verifier-dual-axis.sh|replay verifier dual-axis aggregation (H2 #5)
fixture|tests/scripts/test-h3-input-snapshots.sh|H3 input snapshots (workflow_yaml + constitution + capability_schema, H3 #2)
EOF
}

list_steps() {
  smoke_steps | awk -F'|' '
    $1 == "bind" { printf "%3d. bind    %s\n", NR, $2; next }
    $1 == "fixture" { printf "%3d. fixture %s  # %s\n", NR, $2, $3; next }
    { printf "%3d. unknown %s\n", NR, $2 }
  '
}

run_steps() {
  local kind target label
  while IFS='|' read -r kind target label; do
    [ -z "${kind}" ] && continue
    case "${kind}" in
      bind) run_bind "${target}" ;;
      fixture) run_fixture "${REPO_ROOT}/${target}" "${label}" ;;
      *) report_fail "unknown smoke step kind" "${kind}" ;;
    esac
  done < <(smoke_steps)
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list) list_steps; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

echo "================================================================"
echo "  CAP per-stage workflow smoke"
echo "  repo: ${REPO_ROOT}"
echo "================================================================"

resolve_bind_invoker || true
case "${BIND_INVOKER}" in
  cap_path) echo "  bind invoker: cap (on PATH)" ;;
  cap_workflow_sh) echo "  bind invoker: scripts/cap-workflow.sh (in-repo fallback)" ;;
  "") echo "  bind invoker: <unavailable> - ${BIND_SKIP_REASON}" ;;
esac
echo ""

run_steps

echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed, ${warn_count} skipped"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
