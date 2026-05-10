#!/usr/bin/env bash
#
# test-binder-phase5-attachment.sh — Phase 5 role/skill split binder
# behaviour, exercised through individual binder helpers (matches
# the test-user-imported-role.sh pattern of calling _find_candidates /
# _assert_skill_source_allowed directly so the fixture stays
# independent of ProjectContextLoader / project_id resolution).
#
# Coverage matrix (the strict-attach contract from
# docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md):
#
#   Case 1: kind=skill is NOT an executor candidate via
#           _find_candidates, even when its provided_capabilities
#           lists the requested capability.
#
#   Case 2: kind=skill with attach_to_capabilities matching the
#           step capability attaches with reason
#           ``attach_to_capabilities``.
#
#   Case 3: kind=skill with attach_to_roles matching the role's
#           agent_alias attaches with reason ``attach_to_roles``.
#
#   Case 4: kind=skill present + provided_capabilities matches but
#           NO attach declaration is rejected (auto-fan-in negative).
#
#   Case 5: when both attach_to_capabilities and attach_to_roles
#           would match, attach_to_capabilities wins (precedence).
#
#   Case 6: _find_attached_skills returns empty when role alias
#           doesn't match and capability isn't in any
#           attach_to_capabilities list.
#
#   Case 7: attached skills sorted by priority desc + skill_id asc.
#
#   Case 8: _assert_skill_source_allowed halts with
#           SkillSourcePolicyError when an attached skill's source
#           path is outside effective allowed roots; the error
#           message names purpose=attached_skill.
#
#   Case 9: _build_selected_role rejects an entry with kind=skill
#           even if execution metadata is present (defence in depth).
#
#   Case 10: _build_selected_role returns None for entries missing
#            prompt_file (incompatible role pick).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-binder-phase5-test.XXXXXX)"
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

# ── Sandbox layout ────────────────────────────────────────────────────

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
BUILTIN_BASE="${SANDBOX}/builtin"
mkdir -p "${PROJECT_ROOT}/.cap" "${CAP_HOME_DIR}/shared" "${BUILTIN_BASE}/.cap"

# Builtin layer: one role that owns the cap_demo capability.
cat > "${BUILTIN_BASE}/.cap/skills.yaml" <<'EOF'
schema_version: 2
skills:
  - skill_id: builtin-demo-role
    kind: role
    agent_alias: demo
    cli: claude
    enabled: true
    priority: 100
    prompt_file: agent-skills/demo-agent.md
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - cap_demo
EOF

# Shared layer: five advisory skills covering the attachment matrix.
cat > "${CAP_HOME_DIR}/shared/skills.yaml" <<'EOF'
schema_version: 2
skills:
  - skill_id: shared-cap-advisor
    kind: skill
    agent_alias: cap-advisor
    cli: claude
    enabled: true
    priority: 90
    prompt_file: skills/cap-advisor.md
    provided_capabilities:
      - guardrail_capability
    attach_to_capabilities:
      - cap_demo

  - skill_id: shared-role-advisor
    kind: skill
    agent_alias: role-advisor
    cli: claude
    enabled: true
    priority: 80
    prompt_file: skills/role-advisor.md
    provided_capabilities:
      - guardrail_capability
    attach_to_roles:
      - demo

  - skill_id: shared-no-attach
    kind: skill
    agent_alias: no-attach
    cli: claude
    enabled: true
    priority: 70
    prompt_file: skills/no-attach.md
    # provided_capabilities deliberately lists cap_demo so we can
    # prove auto-fan-in over capability is rejected.
    provided_capabilities:
      - cap_demo

  - skill_id: shared-double-match
    kind: skill
    agent_alias: double-match
    cli: claude
    enabled: true
    priority: 60
    prompt_file: skills/double-match.md
    provided_capabilities:
      - guardrail_capability
    attach_to_capabilities:
      - cap_demo
    attach_to_roles:
      - demo

  - skill_id: shared-priority-low
    kind: skill
    agent_alias: prio-low
    cli: claude
    enabled: true
    priority: 30
    prompt_file: skills/priority-low.md
    provided_capabilities:
      - guardrail_capability
    attach_to_capabilities:
      - cap_demo
EOF

# layered_query <python_expr> — instantiate RuntimeBinder with the
# current sandbox env and print json.dumps(eval(expr)).
layered_query() {
  local expr="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" "${expr}" <<'PY'
import json, sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

project_root, cap_home_dir, builtin_base, expr = sys.argv[1:5]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
print(json.dumps(eval(expr, {"reg": reg, "binder": binder, "RB": RuntimeBinder})))
PY
}

# ── Case 1: kind=skill is not an executor candidate ─────────────────
echo "Case 1: kind=skill is filtered out of _find_candidates"
candidates_for_guardrail="$(layered_query "[c['skill_id'] for c in binder._find_candidates(reg, 'guardrail_capability', 2)]")"
assert_eq "1. _find_candidates([guardrail_capability]) returns []" \
  "[]" "${candidates_for_guardrail}"

# ── Case 2: attach_to_capabilities ──────────────────────────────────
echo "Case 2: attach_to_capabilities reason"
cap_advisor_match="$(layered_query "[(p[0]['skill_id'], p[1]) for p in binder._find_attached_skills(reg, 'cap_demo', workflow_version=2, selected_role_alias='demo') if p[0]['skill_id']=='shared-cap-advisor']")"
assert_contains "2. shared-cap-advisor attaches via attach_to_capabilities" \
  '"attach_to_capabilities"' "${cap_advisor_match}"

# ── Case 3: attach_to_roles ─────────────────────────────────────────
echo "Case 3: attach_to_roles reason"
role_advisor_match="$(layered_query "[(p[0]['skill_id'], p[1]) for p in binder._find_attached_skills(reg, 'cap_demo', workflow_version=2, selected_role_alias='demo') if p[0]['skill_id']=='shared-role-advisor']")"
assert_contains "3. shared-role-advisor attaches via attach_to_roles" \
  '"attach_to_roles"' "${role_advisor_match}"

# ── Case 4: no-attach skill is excluded ─────────────────────────────
echo "Case 4: shared-no-attach is excluded (auto-fan-in negative)"
no_attach_present="$(layered_query "any(p[0]['skill_id']=='shared-no-attach' for p in binder._find_attached_skills(reg, 'cap_demo', workflow_version=2, selected_role_alias='demo'))")"
assert_eq "4. shared-no-attach not in attached_skills" "false" "${no_attach_present}"

# ── Case 5: attach_to_capabilities precedence ───────────────────────
echo "Case 5: attach_to_capabilities precedence on double-match"
double_match_reason="$(layered_query "[p[1] for p in binder._find_attached_skills(reg, 'cap_demo', workflow_version=2, selected_role_alias='demo') if p[0]['skill_id']=='shared-double-match'][0]")"
assert_eq "5. shared-double-match resolves to attach_to_capabilities" \
  '"attach_to_capabilities"' "${double_match_reason}"

# ── Case 6: irrelevant capability + alias → no attachments ──────────
echo "Case 6: empty list when neither capability nor role alias matches"
empty_attach="$(layered_query "[p[0]['skill_id'] for p in binder._find_attached_skills(reg, 'unrelated_capability', workflow_version=2, selected_role_alias='unrelated-role')]")"
assert_eq "6. unrelated capability + alias yields []" "[]" "${empty_attach}"

# ── Case 7: priority sort order ─────────────────────────────────────
echo "Case 7: attached_skills sorted by priority desc + skill_id asc"
sorted_ids="$(layered_query "[p[0]['skill_id'] for p in binder._find_attached_skills(reg, 'cap_demo', workflow_version=2, selected_role_alias='demo')]")"
# Priorities: cap-advisor=90, role-advisor=80, double-match=60, prio-low=30.
# shared-no-attach is filtered (case 4), so the expected ordered list
# has exactly four ids.
expected_sort='["shared-cap-advisor", "shared-role-advisor", "shared-double-match", "shared-priority-low"]'
assert_eq "7. priority desc order" "${expected_sort}" "${sorted_ids}"

# ── Case 8: source policy halt for attached skill outside roots ─────
echo "Case 8: shared attached skill blocked by source policy"
case8_out="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
    "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" <<'PY'
import json, sys
from pathlib import Path
from engine.runtime_binder import (
    RuntimeBinder,
    SkillSourcePolicyError,
)

project_root, cap_home_dir, builtin_base = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
shared_entry = [s for s in reg["skills"] if s["skill_id"] == "shared-cap-advisor"][0]
shared_source_path = shared_entry["_source_path"]

# Effective roots intentionally exclude the shared registry's path —
# only project + builtin layers are honored. Mimics what
# _compute_effective_allowed_roots returns when the project
# constitution sets enforce_allowed_source_roots=true and does NOT
# declare the shared root.
effective = [
    str(Path(builtin_base).resolve()),
    str(Path(project_root).resolve()),
]

try:
    binder._assert_skill_source_allowed(
        {"source_layer": "shared", "source_path": shared_source_path},
        step_id="implement",
        effective_allowed_roots=effective,
        purpose="attached_skill",
        skill_id="shared-cap-advisor",
    )
    print(json.dumps({"halted": False}))
except SkillSourcePolicyError as exc:
    print(json.dumps({
        "halted": True,
        "type": type(exc).__name__,
        "msg": str(exc),
        "stage": exc.stage,
    }))
PY
)"
halted_flag="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1])["halted"])
' "${case8_out}")"
halted_msg="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("msg", ""))
' "${case8_out}")"
halted_stage="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.argv[1]).get("stage", ""))
' "${case8_out}")"
assert_eq "8a. attached skill source-policy violation halts" "True" "${halted_flag}"
assert_eq "8b. halt stage=skill_source_policy" "skill_source_policy" "${halted_stage}"
assert_contains "8c. halt message names purpose=attached_skill" \
  "purpose=attached_skill" "${halted_msg}"
assert_contains "8d. halt message names skill_id of the offending pick" \
  "shared-cap-advisor" "${halted_msg}"

# ── Case 9: _build_selected_role rejects kind=skill ─────────────────
echo "Case 9: _build_selected_role refuses kind=skill"
build_role_skill="$(layered_query "RB._build_selected_role({'skill_id':'foo','agent_alias':'foo','prompt_file':'foo.md','cli':'claude','kind':'skill'})")"
assert_eq "9. selected_role with kind=skill returns None" "null" "${build_role_skill}"

# ── Case 10: _build_selected_role returns None when prompt_file missing ─
echo "Case 10: _build_selected_role refuses missing prompt_file"
build_role_no_prompt="$(layered_query "RB._build_selected_role({'skill_id':'foo','agent_alias':'foo','cli':'claude','kind':'role'})")"
assert_eq "10. selected_role missing prompt_file returns None" "null" "${build_role_no_prompt}"

echo ""
total=$((pass_count + fail_count))
echo "binder-phase5-attachment: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
