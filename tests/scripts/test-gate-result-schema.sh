#!/usr/bin/env bash
#
# test-gate-result-schema.sh — Validate
# schemas/gate-result.schema.yaml against positive and negative
# fixtures using step_runtime.py validate-jsonschema.
#
# IMPORTANT: this is a forward contract. fixtures describe the
# **expected P8 governance gate runner output** (Watcher / Security /
# QA / Logger), NOT a retrofit of any current artifact. Today's gates
# only emit free-form prose via Type D handoff summaries.
#
# Coverage:
#   Positive 1: Watcher milestone gate, clean pass (no findings)
#   Positive 2: QA Lighthouse fail at HIGH risk with finding +
#               metrics + fail_routing route_back_to + related_gate_ids
#   Negative 1: missing required top-level field (gate_type)
#   Negative 2: gate_type not in enum
#   Negative 3: result not in enum
#   Negative 4: risk_level not in enum
#   Negative 5: finding missing required severity
#   Negative 6: finding severity not in enum
#   Negative 7: fail_routing.action not in enum
#   Negative 8: schema_version not in supported enum

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/gate-result.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-gateresult-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

validate_fixture() {
  local fixture_path="$1"
  "${PYTHON_BIN}" "${STEP_PY}" validate-jsonschema "${fixture_path}" "${SCHEMA_PATH}" >/dev/null 2>&1
  echo $?
}

write_fixture() {
  local name="$1" payload="$2"
  local path="${SANDBOX}/${name}.json"
  printf '%s\n' "${payload}" > "${path}"
  printf '%s' "${path}"
}

# ── Positive 1: Watcher milestone gate, clean pass ──────────────────
echo "Positive 1: Watcher milestone gate clean pass (no findings, low risk)"
fixture="$(write_fixture "pos-watcher-pass" '{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "gate_subtype": "structure_audit",
  "checkpoint": "spec_phase",
  "workflow_id": "project-spec-pipeline",
  "run_id": "run_20260502023000_aaaaaaaa",
  "step_id": "spec_audit",
  "project_id": "smoke-proj",
  "task_id": "token-monitor-minimal-spec",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "target_artifacts": [
    "/run/3-ba.md",
    "/run/2-tech_plan.md"
  ],
  "result": "pass",
  "risk_level": "low",
  "summary": "Spec coherence check passed; no schema drift between BA and TechPlan.",
  "findings": [],
  "metrics": {
    "checks_executed": 17,
    "checks_passed": 17,
    "checks_failed": 0
  }
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on watcher clean pass" "0" "${rc}"

# ── Positive 2: QA Lighthouse fail with finding + fail_routing ──────
echo "Positive 2: QA Lighthouse fail at HIGH risk with finding + metrics + fail_routing"
fixture="$(write_fixture "pos-qa-lh-fail" '{
  "schema_version": 1,
  "gate_id": "lighthouse_audit",
  "gate_type": "qa",
  "gate_subtype": "lighthouse_audit",
  "checkpoint": "pre_release",
  "workflow_id": "project-qa-pipeline",
  "run_id": "run_20260502024500_bbbbbbbb",
  "step_id": "lighthouse_audit",
  "project_id": "charlie-ai-protocols",
  "task_id": null,
  "produced_at": "2026-05-02T02:45:30+08:00",
  "produced_by": "07-QA",
  "target_artifacts": [
    "/run/lh/landing.report.json",
    "/run/lh/landing.report.html"
  ],
  "result": "fail",
  "risk_level": "high",
  "summary": "Lighthouse performance regressed below threshold (52 < 80); LCP 4.8s, CLS 0.18.",
  "findings": [
    {
      "finding_id": "F-LH-001",
      "severity": "high",
      "category": "lh_perf_fail",
      "location": "/landing",
      "description": "LCP element is the hero image rendered without preload; main-thread blocking on third-party analytics script delays paint.",
      "recommendation": "Preload hero image; defer non-essential analytics until after first interaction.",
      "target_capability": "frontend_implementation"
    },
    {
      "finding_id": "F-LH-002",
      "severity": "medium",
      "category": "lh_a11y_warn",
      "location": "/landing",
      "description": "Two CTA buttons share the same accessible name; screen readers cannot distinguish.",
      "recommendation": "Add aria-label to differentiate primary vs secondary CTA."
    }
  ],
  "metrics": {
    "performance": 52,
    "accessibility": 88,
    "best_practices": 95,
    "seo": 92,
    "lcp_ms": 4800,
    "cls": 0.18,
    "inp_ms": 240,
    "thresholds": {
      "performance_min": 80,
      "accessibility_min": 90
    }
  },
  "fail_routing": {
    "action": "route_back",
    "route_back_to_step": "frontend_implementation",
    "reason": "Performance regression must be fixed in implementation phase before re-running QA gate."
  },
  "remediation_status": "not_started",
  "related_gate_ids": ["qa_e2e", "k6_perf_smoke"]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on QA Lighthouse fail with full envelope" "0" "${rc}"

# ── Negative 1: missing required top-level (gate_type) ──────────────
echo "Negative 1: missing required top-level (gate_type)"
fixture="$(write_fixture "neg-no-gate-type" '{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "result": "pass",
  "risk_level": "low"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when gate_type missing" "1" "${rc}"

# ── Negative 2: gate_type not in enum ───────────────────────────────
echo "Negative 2: gate_type not in enum"
fixture="$(write_fixture "neg-bad-gate-type" '{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "vibes",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "result": "pass",
  "risk_level": "low"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when gate_type not in enum" "1" "${rc}"

# ── Negative 3: result not in enum ──────────────────────────────────
echo "Negative 3: result not in enum"
fixture="$(write_fixture "neg-bad-result" '{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "result": "maybe",
  "risk_level": "low"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when result not in enum" "1" "${rc}"

# ── Negative 4: risk_level not in enum ──────────────────────────────
echo "Negative 4: risk_level not in enum"
fixture="$(write_fixture "neg-bad-risk" '{
  "schema_version": 1,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "result": "pass",
  "risk_level": "spicy"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when risk_level not in enum" "1" "${rc}"

# ── Negative 5: finding missing severity ────────────────────────────
echo "Negative 5: finding missing required severity"
fixture="$(write_fixture "neg-finding-no-severity" '{
  "schema_version": 1,
  "gate_id": "security_scan",
  "gate_type": "security",
  "checkpoint": "pre_merge",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "08-Security",
  "result": "fail",
  "risk_level": "high",
  "findings": [
    {"category": "secret_leak", "description": "API key found in commit"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when finding missing severity" "1" "${rc}"

# ── Negative 6: finding severity not in enum ────────────────────────
echo "Negative 6: finding severity not in enum"
fixture="$(write_fixture "neg-finding-bad-severity" '{
  "schema_version": 1,
  "gate_id": "security_scan",
  "gate_type": "security",
  "checkpoint": "pre_merge",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "08-Security",
  "result": "fail",
  "risk_level": "high",
  "findings": [
    {"severity": "spicy", "category": "secret_leak", "description": "API key found"}
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when finding severity not in enum" "1" "${rc}"

# ── Negative 7: fail_routing.action not in enum ─────────────────────
echo "Negative 7: fail_routing.action not in enum"
fixture="$(write_fixture "neg-fail-routing-bad-action" '{
  "schema_version": 1,
  "gate_id": "qa_e2e",
  "gate_type": "qa",
  "checkpoint": "pre_release",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "07-QA",
  "result": "fail",
  "risk_level": "high",
  "fail_routing": {"action": "yolo", "route_back_to_step": "ba"}
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when fail_routing.action not in enum" "1" "${rc}"

# ── Negative 8: schema_version not in enum ──────────────────────────
echo "Negative 8: schema_version not in enum"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 99,
  "gate_id": "spec_audit",
  "gate_type": "watcher",
  "checkpoint": "spec_phase",
  "workflow_id": "wf",
  "run_id": "r",
  "step_id": "s",
  "project_id": "p",
  "produced_at": "2026-05-02T02:30:00+08:00",
  "produced_by": "90-Watcher",
  "result": "pass",
  "risk_level": "low"
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when schema_version unsupported" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
