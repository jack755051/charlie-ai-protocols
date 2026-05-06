#!/usr/bin/env bash
#
# test-binding-report-schema.sh — Validate
# schemas/binding-report.schema.yaml against positive and negative
# fixtures using step_runtime.py validate-jsonschema.
#
# Coverage:
#   Positive 1: minimal binding report (empty steps, ready status)
#   Positive 2: realistic mixed report (one resolved, one fallback, one
#               unresolved, with nullable fields exercised)
#   Negative 1: missing required top-level (summary)
#   Negative 2: missing required step field (selected_cli)
#   Negative 3: invalid binding_status enum
#   Negative 4: invalid resolution_status enum
#   Negative 5: summary missing required field (resolved_steps)
#   Negative 6: selected_skill_id wrong type (integer)
#   Negative 7: schema_version not in enum
#   Negative 8: candidate_skill_ids contains non-string
#
# Per MISSING-IMPLEMENTATION-CHECKLIST P0 #3 acceptance: schema can
# validate resolved / unresolved / fallback / provider_cli / source_priority.
# Mapping:
#   resolved/unresolved/fallback   → step.resolution_status enum + summary counts
#   provider_cli                   → step.selected_cli (nullable string)
#   source_priority                → registry_source_path + adapter_from_legacy
#                                    + project_context.binding_policy
# `executor` is not a top-level field; see schema header for the SSOT
# rationale and how executor type is encoded via selected_provider +
# selected_skill_id.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEMA_PATH="${REPO_ROOT}/schemas/binding-report.schema.yaml"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
VENV_PY="${REPO_ROOT}/.venv/bin/python"
if [ -x "${VENV_PY}" ]; then
  PYTHON_BIN="${VENV_PY}"
else
  PYTHON_BIN="python3"
fi

[ -f "${SCHEMA_PATH}" ] || { echo "FAIL: schema not found at ${SCHEMA_PATH}"; exit 1; }
[ -f "${STEP_PY}" ]    || { echo "FAIL: step_runtime.py not found"; exit 1; }

SANDBOX="$(mktemp -d -t cap-bindrep-test.XXXXXX)"
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

# ── Positive 1: minimal valid binding report ────────────────────────
echo "Positive 1: minimal valid binding report (empty steps, ready)"
fixture="$(write_fixture "pos-min" '{
  "schema_version": 1,
  "workflow_id": "compiled-smoke-min-001",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {
    "total_steps": 0,
    "resolved_steps": 0,
    "fallback_steps": 0,
    "unresolved_required_steps": 0,
    "unresolved_optional_steps": 0
  },
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on minimal valid binding report" "0" "${rc}"

# ── Positive 2: realistic mixed report ──────────────────────────────
echo "Positive 2: realistic mixed report (resolved + fallback + blocked)"
fixture="$(write_fixture "pos-mixed" '{
  "schema_version": 1,
  "workflow_id": "compiled-token-monitor-minimal-spec",
  "workflow_version": 2,
  "binding_status": "degraded",
  "registry_source_path": "/home/u/.cap/registries/skills.yaml",
  "project_context": {
    "binding_policy": {
      "allowed_capabilities": ["prd_generation", "technical_planning", "tool_spec_audit"],
      "preferred_cli": "claude",
      "source_priority": ["project", "shared", "builtin"]
    }
  },
  "registry_missing": false,
  "adapter_from_legacy": false,
  "contract_missing_steps": [],
  "summary": {
    "total_steps": 3,
    "resolved_steps": 1,
    "fallback_steps": 1,
    "unresolved_required_steps": 0,
    "unresolved_optional_steps": 1
  },
  "steps": [
    {
      "step_id": "prd",
      "phase": 4,
      "capability": "prd_generation",
      "optional": false,
      "resolution_status": "resolved",
      "selected_skill_id": "supervisor-prd-claude",
      "selected_provider": "claude",
      "selected_agent_alias": "supervisor",
      "selected_prompt_file": "agent-skills/01-supervisor-agent.md",
      "selected_cli": "claude",
      "binding_mode": "strict",
      "missing_policy": "halt",
      "reason": "found compatible skill",
      "candidate_skill_ids": ["supervisor-prd-claude", "supervisor-prd-codex"]
    },
    {
      "step_id": "tech_plan",
      "phase": 5,
      "capability": "technical_planning",
      "optional": false,
      "resolution_status": "fallback_available",
      "selected_skill_id": "generic-supervisor-fallback",
      "selected_provider": "claude",
      "selected_agent_alias": "supervisor",
      "selected_prompt_file": "agent-skills/01-supervisor-agent.md",
      "selected_cli": "claude",
      "binding_mode": "allow_fallback",
      "missing_policy": "fallback_generic",
      "reason": "no direct skill; generic fallback available",
      "candidate_skill_ids": []
    },
    {
      "step_id": "ui",
      "phase": 9,
      "capability": "ui_design",
      "optional": true,
      "resolution_status": "optional_unresolved",
      "selected_skill_id": null,
      "selected_provider": null,
      "selected_agent_alias": null,
      "selected_prompt_file": null,
      "selected_cli": null,
      "binding_mode": "allow_fallback",
      "missing_policy": "skip_optional",
      "reason": "no compatible skill found in registry",
      "candidate_skill_ids": []
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 0 on realistic mixed report" "0" "${rc}"

# ── Negative 1: missing required top-level (summary) ────────────────
echo "Negative 1: missing required top-level (summary)"
fixture="$(write_fixture "neg-no-summary" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when summary missing" "1" "${rc}"

# ── Negative 2: missing required step field (selected_cli) ──────────
echo "Negative 2: missing required step field (selected_cli)"
fixture="$(write_fixture "neg-step-no-cli" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 1, "resolved_steps": 1, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": [
    {
      "step_id": "prd", "phase": 1, "capability": "prd_generation", "optional": false,
      "resolution_status": "resolved",
      "selected_skill_id": "x", "selected_provider": "claude",
      "selected_agent_alias": "supervisor", "selected_prompt_file": "x",
      "binding_mode": "strict", "missing_policy": "halt", "reason": "x"
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when step.selected_cli missing" "1" "${rc}"

# ── Negative 3: invalid binding_status enum ─────────────────────────
echo "Negative 3: invalid binding_status enum"
fixture="$(write_fixture "neg-bad-bind-status" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "yolo",
  "summary": {"total_steps": 0, "resolved_steps": 0, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when binding_status not in enum" "1" "${rc}"

# ── Negative 4: invalid resolution_status enum ──────────────────────
echo "Negative 4: invalid resolution_status enum"
fixture="$(write_fixture "neg-bad-res-status" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 1, "resolved_steps": 1, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": [
    {
      "step_id": "prd", "phase": 1, "capability": "prd_generation", "optional": false,
      "resolution_status": "magically_resolved",
      "selected_skill_id": null, "selected_provider": null,
      "selected_agent_alias": null, "selected_prompt_file": null, "selected_cli": null,
      "binding_mode": "strict", "missing_policy": "halt", "reason": "x"
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when resolution_status not in enum" "1" "${rc}"

# ── Negative 5: summary missing resolved_steps ──────────────────────
echo "Negative 5: summary missing required field (resolved_steps)"
fixture="$(write_fixture "neg-summary-no-resolved" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 0, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when summary.resolved_steps missing" "1" "${rc}"

# ── Negative 6: selected_skill_id wrong type ────────────────────────
echo "Negative 6: selected_skill_id wrong type (integer)"
fixture="$(write_fixture "neg-skill-id-int" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 1, "resolved_steps": 1, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": [
    {
      "step_id": "prd", "phase": 1, "capability": "prd_generation", "optional": false,
      "resolution_status": "resolved",
      "selected_skill_id": 42,
      "selected_provider": null, "selected_agent_alias": null,
      "selected_prompt_file": null, "selected_cli": null,
      "binding_mode": "strict", "missing_policy": "halt", "reason": "x"
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when selected_skill_id is integer (not string|null)" "1" "${rc}"

# ── Negative 7: schema_version not in enum ──────────────────────────
echo "Negative 7: schema_version not in enum"
fixture="$(write_fixture "neg-bad-version" '{
  "schema_version": 99,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 0, "resolved_steps": 0, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": []
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when schema_version unsupported" "1" "${rc}"

# ── Negative 8: candidate_skill_ids contains non-string ─────────────
echo "Negative 8: candidate_skill_ids contains non-string"
fixture="$(write_fixture "neg-cand-int" '{
  "schema_version": 1,
  "workflow_id": "x",
  "workflow_version": 2,
  "binding_status": "ready",
  "summary": {"total_steps": 1, "resolved_steps": 1, "fallback_steps": 0, "unresolved_required_steps": 0, "unresolved_optional_steps": 0},
  "steps": [
    {
      "step_id": "prd", "phase": 1, "capability": "prd_generation", "optional": false,
      "resolution_status": "resolved",
      "selected_skill_id": "x", "selected_provider": "claude",
      "selected_agent_alias": "supervisor", "selected_prompt_file": "x",
      "selected_cli": "claude",
      "binding_mode": "strict", "missing_policy": "halt", "reason": "x",
      "candidate_skill_ids": ["good-skill", 42]
    }
  ]
}')"
rc="$(validate_fixture "${fixture}")"
assert_eq "exit 1 when candidate_skill_ids item is non-string" "1" "${rc}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
