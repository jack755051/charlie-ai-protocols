#!/usr/bin/env bash
#
# test-user-imported-role.sh — Role/Skill Registry Phase 3 focused test.
#
# Verifies that user-imported NEW roles (kind=role, registered in
# project / shared layer with new capability) are discoverable by
# RuntimeBinder without any runtime changes.
#
# Reference SSOT:
#   - policies/agent-skills-baseline.md §3.5 (normative)
#   - docs/cap/AGENT-SKILLS-CUSTOMIZATION.md 場景 5 (how-to)
#   - docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md Phase 3
#   - schemas/skill-registry.schema.yaml Examples A/B
#
# Phase 3 boundary: this fixture asserts ONLY the resolver + source
# policy paths already shipped before v0.24.11. No runtime attachment
# logic is exercised; that lives in Phase 5.
#
# Cases:
#   1. project-layer NEW role (kind=role + new capability) is found
#      by _find_candidates and tagged _source_layer=project
#   2. shared-layer NEW role with constitution explicitly allowing the
#      shared registry passes _assert_skill_source_allowed
#   3. shared-layer NEW role with enforce_allowed_source_roots=true
#      but NO declaration triggers SkillSourcePolicyError (negative test)
#   4. project + shared both register NEW role with same skill_id —
#      project wins (layer order applies to user roles too)
#   5. user role's NEW capability is isolated — it doesn't accidentally
#      shadow builtin capability candidates
#   6. kind=role but missing prompt_file fails _has_execution_metadata
#      (user roles must satisfy the same execution metadata rules)
#
# Sandbox layout mirrors test-skill-registry-resolver.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-user-imported-role-test.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "${haystack}" in
    *"${needle}"*)
      echo "  PASS: ${desc}"
      pass_count=$((pass_count + 1)) ;;
    *)
      echo "  FAIL: ${desc}"
      echo "    expected substring: ${needle}"
      echo "    actual:             ${haystack}"
      fail_count=$((fail_count + 1)) ;;
  esac
}

write_skills() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "${path}")"
  printf '%s' "${body}" > "${path}"
}

# ── Sandbox layout ────────────────────────────────────────────────────

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
BUILTIN_BASE="${SANDBOX}/builtin"
mkdir -p "${PROJECT_ROOT}/.cap" "${CAP_HOME_DIR}/shared" "${BUILTIN_BASE}/.cap"

# Builtin layer baseline — one role with capability that user roles
# in cases 1/5 should NOT shadow.
write_skills "${BUILTIN_BASE}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: builtin-frontend
    kind: role
    agent_alias: frontend
    provider: builtin
    enabled: true
    priority: 100
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
EOF
)"

# layered_query <python_expr> — instantiate RuntimeBinder with the
# current sandbox env and print eval(<expr>).
layered_query() {
  local expr="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" "${expr}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

project_root, cap_home_dir, builtin_base, expr = sys.argv[1:5]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
print(eval(expr, {"reg": reg, "binder": binder}))
PY
}

# ── Case 1: project-layer NEW role ────────────────────────────────────

echo "Case 1: project-layer NEW role (kind=role, new capability)"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: project-mobile-agent
    kind: role
    agent_alias: mobile
    provider: project
    enabled: true
    priority: 100
    prompt_file: agent-skills/mobile-agent.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - mobile_implementation
    fallback_roles:
      - implementer
EOF
)"

assert_eq "case1: project-mobile-agent loaded with kind=role" "role" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-mobile-agent'][0]['kind']")"
assert_eq "case1: project-mobile-agent _source_layer=project" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-mobile-agent'][0]['_source_layer']")"

# _find_candidates discovers it for the new capability
assert_eq "case1: _find_candidates finds project-mobile-agent for mobile_implementation" "1" \
  "$(layered_query "len([c for c in binder._find_candidates(reg, 'mobile_implementation', 1) if c['skill_id']=='project-mobile-agent'])")"
# _has_execution_metadata accepts the user role
assert_eq "case1: _has_execution_metadata accepts user role" "True" \
  "$(layered_query "binder._has_execution_metadata([s for s in reg['skills'] if s['skill_id']=='project-mobile-agent'][0])")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 2: shared-layer NEW role with explicit allowed_source_roots ──

echo ""
echo "Case 2: shared-layer NEW role passes source policy when explicitly allowed"
write_skills "${CAP_HOME_DIR}/shared/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: shared-api-reviewer
    kind: role
    agent_alias: api-reviewer
    provider: shared
    enabled: true
    priority: 90
    prompt_file: shared/prompts/api-reviewer.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - api_contract_review
EOF
)"

CASE2_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

project_root, cap_home_dir, builtin_base = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
shared_entry = [s for s in reg["skills"] if s["skill_id"] == "shared-api-reviewer"][0]
source_path = shared_entry["_source_path"]

# Constitution explicitly allows the shared registry path.
project_context = {
    "workflow_policy": {
        "enforce_allowed_source_roots": True,
        "allowed_source_roots": [source_path],
    }
}
effective = binder._compute_effective_allowed_roots(project_context)
print(f"effective_count={len(effective)}")
print(f"shared_in_effective={source_path in effective}")

# _assert_skill_source_allowed should NOT raise for the shared entry
try:
    binder._assert_skill_source_allowed(
        {"source_path": source_path, "source_layer": "shared"},
        step_id="review_api_contracts",
        effective_allowed_roots=effective,
    )
    print("policy_check=allowed")
except Exception as exc:
    print(f"policy_check=blocked:{type(exc).__name__}")
PY
)"

assert_contains "case2: shared path is in effective_allowed_roots" \
  "shared_in_effective=True" "${CASE2_OUT}"
assert_contains "case2: source policy allows the shared role" \
  "policy_check=allowed" "${CASE2_OUT}"

# ── Case 3: shared-layer NEW role WITHOUT declaration → blocked ────────

echo ""
echo "Case 3: shared-layer NEW role blocked when not declared (negative test)"
# (CAP_HOME_DIR/shared/skills.yaml from case 2 still in place)

CASE3_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder, SkillSourcePolicyError

project_root, cap_home_dir, builtin_base = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
shared_entry = [s for s in reg["skills"] if s["skill_id"] == "shared-api-reviewer"][0]
source_path = shared_entry["_source_path"]

# enforce_allowed_source_roots=True but allowed_source_roots is empty
# → only implicit project + builtin layers allowed; shared NOT allowed.
project_context = {
    "workflow_policy": {
        "enforce_allowed_source_roots": True,
        "allowed_source_roots": [],
    }
}
effective = binder._compute_effective_allowed_roots(project_context)
print(f"shared_in_effective={source_path in effective}")

try:
    binder._assert_skill_source_allowed(
        {"source_path": source_path, "source_layer": "shared"},
        step_id="review_api_contracts",
        effective_allowed_roots=effective,
    )
    print("policy_check=allowed")
except SkillSourcePolicyError as exc:
    print("policy_check=blocked:SkillSourcePolicyError")
    print(f"halt_stage={exc.stage}")
PY
)"

assert_contains "case3: shared path NOT in effective_allowed_roots (no declaration)" \
  "shared_in_effective=False" "${CASE3_OUT}"
assert_contains "case3: SkillSourcePolicyError raised" \
  "policy_check=blocked:SkillSourcePolicyError" "${CASE3_OUT}"
assert_contains "case3: halt stage = skill_source_policy" \
  "halt_stage=skill_source_policy" "${CASE3_OUT}"

rm -f "${CAP_HOME_DIR}/shared/skills.yaml"

# ── Case 4: project + shared same skill_id → project wins ─────────────

echo ""
echo "Case 4: project + shared same skill_id — project wins"
write_skills "${CAP_HOME_DIR}/shared/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: user-mobile-agent
    kind: role
    agent_alias: mobile
    provider: shared
    enabled: true
    priority: 90
    prompt_file: shared/prompts/mobile-shared.md
    cli: codex
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - mobile_implementation
EOF
)"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: user-mobile-agent
    kind: role
    agent_alias: mobile
    provider: project
    enabled: true
    priority: 100
    prompt_file: agent-skills/mobile-project.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - mobile_implementation
EOF
)"

assert_eq "case4: user-mobile-agent _source_layer=project (wins)" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='user-mobile-agent'][0]['_source_layer']")"
assert_eq "case4: user-mobile-agent cli=claude (project wins)" "claude" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='user-mobile-agent'][0]['cli']")"
# Single entry after merge (shared dropped)
assert_eq "case4: only one user-mobile-agent after merge" "1" \
  "$(layered_query "len([s for s in reg['skills'] if s['skill_id']=='user-mobile-agent'])")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml" "${CAP_HOME_DIR}/shared/skills.yaml"

# ── Case 5: capability isolation — user role doesn't shadow builtin ───

echo ""
echo "Case 5: user role's NEW capability is isolated from builtin"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: project-mobile-agent
    kind: role
    agent_alias: mobile
    provider: project
    enabled: true
    priority: 100
    prompt_file: agent-skills/mobile-agent.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - mobile_implementation
EOF
)"

# builtin frontend_implementation candidates only contain builtin-frontend
assert_eq "case5: frontend_implementation candidates count = 1 (builtin only)" "1" \
  "$(layered_query "len(binder._find_candidates(reg, 'frontend_implementation', 1))")"
assert_eq "case5: frontend_implementation candidate = builtin-frontend" "builtin-frontend" \
  "$(layered_query "binder._find_candidates(reg, 'frontend_implementation', 1)[0]['skill_id']")"
# user role doesn't appear under builtin capability
assert_eq "case5: project-mobile-agent NOT a frontend candidate" "0" \
  "$(layered_query "len([c for c in binder._find_candidates(reg, 'frontend_implementation', 1) if c['skill_id']=='project-mobile-agent'])")"
# builtin doesn't appear under user capability
assert_eq "case5: builtin-frontend NOT a mobile candidate" "0" \
  "$(layered_query "len([c for c in binder._find_candidates(reg, 'mobile_implementation', 1) if c['skill_id']=='builtin-frontend'])")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 6: kind=role missing prompt_file fails execution metadata ────

echo ""
echo "Case 6: kind=role missing prompt_file fails _has_execution_metadata"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 2
skills:
  - skill_id: project-broken-role
    kind: role
    agent_alias: broken
    provider: project
    enabled: true
    priority: 100
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - broken_capability
EOF
)"

# Entry loads (registry doesn't reject malformed entries this way),
# AND _find_candidates returns it (capability match), BUT
# _has_execution_metadata rejects it so the binder won't actually
# spawn it as an executor. This is the same gate that bin selection
# applies for all roles, builtin or user-imported.
assert_eq "case6: broken role still loaded (registry doesn't pre-filter)" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-broken-role'][0]['_source_layer']")"
assert_eq "case6: broken role appears as candidate (capability match)" "1" \
  "$(layered_query "len([c for c in binder._find_candidates(reg, 'broken_capability', 1) if c['skill_id']=='project-broken-role'])")"
assert_eq "case6: _has_execution_metadata rejects broken role" "False" \
  "$(layered_query "binder._has_execution_metadata([s for s in reg['skills'] if s['skill_id']=='project-broken-role'][0])")"

echo ""
total=$((pass_count + fail_count))
echo "user-imported-role: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
