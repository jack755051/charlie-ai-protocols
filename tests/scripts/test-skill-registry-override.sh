#!/usr/bin/env bash
#
# test-skill-registry-override.sh — A0 #2 focused test.
#
# Exercises the v0.22.0+ override contract added on top of the P9 #3
# layered skill registry resolver:
#   * disabled: true tombstone mask (project layer can hide a builtin
#     skill_id, low-layer entry cannot be reanimated as fallback).
#   * replaces: <other_skill_id> renames + masks the target, optionally
#     inheriting capabilities when the replacement omits them.
#   * conflict cases: multiple `replaces` against the same target halt
#     via OverrideContractError; non-existent target is warn-but-accept.
#
# Reference SSOT:
#   - policies/agent-skills-baseline.md §4
#   - engine/runtime_binder.py:_apply_override_contract / _collect_masked_hint
#
# All cases drive the loader with explicit project_root / cap_home
# kwargs to keep them isolated from the live cap-protocols repo and
# the user's real ~/.cap.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-skill-registry-override-test.XXXXXX)"
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

# layered_query <python_expr> — instantiate RuntimeBinder with sandbox
# env and print eval result against the loaded registry.
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
print(eval(expr, {"reg": reg}))
PY
}

# layered_run <python_body> — run a custom Python snippet against a
# RuntimeBinder bound to the sandbox; snippet receives `binder` and
# `Path` in scope.
layered_run() {
  local body="$1"
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" <<PY
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder, OverrideContractError

project_root, cap_home_dir, builtin_base = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
${body}
PY
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

# Common builtin registry — supplies builtin-figma + builtin-frontend
# + a generic-implementer fallback so cases can verify mask blocks
# fallback resolution too.
write_skills "${BUILTIN_BASE}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: builtin
binding_defaults:
  binding_mode: strict
  missing_policy: halt
skills:
  - skill_id: builtin-figma
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - figma_sync
    fallback_roles:
      - implementer
    agent_alias: figma
    prompt_file: agent-skills/12-figma-agent.md
    cli: codex
  - skill_id: builtin-frontend
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/04-frontend-agent.md
    cli: codex
  - skill_id: generic-implementer
    provider: builtin
    enabled: true
    priority: 10
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities: []
    fallback_roles:
      - implementer
    agent_alias: generic-implementer
    prompt_file: agent-skills/04-frontend-agent.md
    cli: codex
EOF
)"

# ── Case 1: disabled tombstone masks builtin skill_id ────────────────

echo "Case 1: project tombstone disables builtin-figma"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: builtin-figma
    disabled: true
EOF
)"

assert_eq "case1: builtin-figma _masked=True" "True" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-figma'][0].get('_masked', False)")"
assert_eq "case1: builtin-figma _mask_reason=disabled" "disabled" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-figma'][0].get('_mask_reason')")"
# Underlying-layer capability inheritance lets audit hint know what was hidden.
assert_eq "case1: tombstone inherits provided_capabilities from builtin layer" \
  "['figma_sync']" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-figma'][0].get('provided_capabilities')")"
assert_eq "case1: inheritance flag set" "True" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-figma'][0].get('_capabilities_inherited_from_underlying', False)")"

# _find_candidates must skip the masked entry.
CASE1_CANDIDATES="$(layered_run "
candidates = binder._find_candidates(binder.load_skill_registry(), 'figma_sync', 1)
print('count=' + str(len(candidates)))
for c in candidates:
    print('id=' + c['skill_id'])
")"
assert_contains "case1: figma_sync has no candidates after mask" "count=0" "${CASE1_CANDIDATES}"

# Audit hint surfaces in unresolved reason.
CASE1_HINT="$(layered_run "
reg = binder.load_skill_registry()
hint = binder._collect_masked_hint(reg, 'figma_sync')
print('hint=' + (hint or '<none>'))
")"
assert_contains "case1: masked hint mentions builtin-figma" "'builtin-figma'" "${CASE1_HINT}"
assert_contains "case1: masked hint mentions disabled reason" "disabled" "${CASE1_HINT}"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 2: replaces inherits capabilities when own list omitted ─────

echo ""
echo "Case 2: replacement skill inherits capabilities (own list omitted)"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: my-frontend-react18
    replaces: builtin-frontend
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/frontend-react18.md
    cli: claude
EOF
)"

assert_eq "case2: builtin-frontend _masked=True after replaces" "True" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-frontend'][0].get('_masked', False)")"
assert_eq "case2: builtin-frontend _mask_reason=replaced_by=my-frontend-react18" \
  "replaced_by=my-frontend-react18" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-frontend'][0].get('_mask_reason')")"
assert_eq "case2: my-frontend-react18 inherits provided_capabilities" \
  "['frontend_implementation']" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='my-frontend-react18'][0].get('provided_capabilities')")"
assert_eq "case2: inheritance attribution set" "builtin-frontend" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='my-frontend-react18'][0].get('_capabilities_inherited_from')")"

# Replacement is the only candidate; masked target excluded.
CASE2_CANDIDATES="$(layered_run "
candidates = binder._find_candidates(binder.load_skill_registry(), 'frontend_implementation', 1)
print('count=' + str(len(candidates)))
print('first=' + (candidates[0]['skill_id'] if candidates else '<none>'))
")"
assert_contains "case2: frontend_implementation candidate count=1" "count=1" "${CASE2_CANDIDATES}"
assert_contains "case2: frontend_implementation candidate is replacement" \
  "first=my-frontend-react18" "${CASE2_CANDIDATES}"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 3: replaces with own capabilities → no inheritance ──────────

echo ""
echo "Case 3: replacement specifies provided_capabilities (no inheritance)"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: my-frontend-extended
    replaces: builtin-frontend
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
      - frontend_a11y_audit
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/frontend-extended.md
    cli: claude
EOF
)"

assert_eq "case3: replacement keeps own provided_capabilities" \
  "['frontend_implementation', 'frontend_a11y_audit']" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='my-frontend-extended'][0].get('provided_capabilities')")"
# Inheritance attribution must NOT be set when own list is provided.
assert_eq "case3: no inheritance attribution" "None" \
  "$(layered_query "str([s for s in reg['skills'] if s['skill_id']=='my-frontend-extended'][0].get('_capabilities_inherited_from'))")"
assert_eq "case3: builtin-frontend still masked" "True" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-frontend'][0].get('_masked', False)")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 4: multiple replaces same target → OverrideContractError ────

echo ""
echo "Case 4: multiple skills replacing the same target raise OverrideContractError"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: alt-frontend-a
    replaces: builtin-frontend
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
  - skill_id: alt-frontend-b
    replaces: builtin-frontend
    provider: builtin
    enabled: true
    priority: 105
    compatible_workflow_versions: [1, 2, 3]
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
EOF
)"

CASE4_OUT="$(layered_run "
try:
    binder.load_skill_registry()
    print('result=no-error')
except OverrideContractError as exc:
    print('result=OverrideContractError')
    for err in exc.errors:
        print('err=' + err)
")"
assert_contains "case4: OverrideContractError raised" "result=OverrideContractError" "${CASE4_OUT}"
assert_contains "case4: error names target builtin-frontend" "builtin-frontend" "${CASE4_OUT}"
assert_contains "case4: error names alt-frontend-a" "alt-frontend-a" "${CASE4_OUT}"
assert_contains "case4: error names alt-frontend-b" "alt-frontend-b" "${CASE4_OUT}"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 5: replaces non-existent target → warn-but-accept ───────────

echo ""
echo "Case 5: replaces target absent from registry — warn-but-accept"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: my-marketplace-skill
    replaces: not-yet-installed-skill
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
EOF
)"

assert_eq "case5: my-marketplace-skill loaded" "my-marketplace-skill" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='my-marketplace-skill'][0]['skill_id']")"
# The replacement keeps its own capabilities; no inheritance from missing target.
assert_eq "case5: replacement keeps explicit capabilities" \
  "['frontend_implementation']" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='my-marketplace-skill'][0].get('provided_capabilities')")"
# builtin-frontend untouched (different target).
assert_eq "case5: builtin-frontend not masked" "False" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-frontend'][0].get('_masked', False)")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 6: disabled + replaces on same entry → disabled wins ────────

echo ""
echo "Case 6: disabled + replaces on same entry — disabled wins"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: project-mixed-entry
    disabled: true
    replaces: builtin-frontend
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    fallback_roles:
      - implementer
    agent_alias: frontend
    prompt_file: agent-skills/04-frontend-agent.md
    cli: claude
EOF
)"

assert_eq "case6: project-mixed-entry _masked=True" "True" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-mixed-entry'][0].get('_masked', False)")"
assert_eq "case6: project-mixed-entry mask reason=disabled (not replacement)" \
  "disabled" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-mixed-entry'][0].get('_mask_reason')")"
# Because `disabled` excludes the entry from the Pass-1 replaces scan,
# the target builtin-frontend should NOT be masked.
assert_eq "case6: builtin-frontend NOT masked when replacer is disabled" "False" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='builtin-frontend'][0].get('_masked', False)")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 7: masked entry not picked by _find_fallback ────────────────

echo ""
echo "Case 7: _find_fallback skips masked entries (mask blocks fallback path)"
# Builtin layer has three skills with fallback_roles=[implementer]:
# builtin-figma, builtin-frontend, generic-implementer. To verify the
# mask actually shuts down the fallback path, disable all three.
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
skills:
  - skill_id: builtin-figma
    disabled: true
  - skill_id: builtin-frontend
    disabled: true
  - skill_id: generic-implementer
    disabled: true
EOF
)"

CASE7_OUT="$(layered_run "
fb = binder._find_fallback(binder.load_skill_registry(), 'frontend_implementation')
print('fallback=' + (fb['skill_id'] if fb else '<none>'))
")"
# All three implementer-eligible skills are masked; no fallback survives.
assert_contains "case7: no fallback after every implementer skill masked" \
  "fallback=<none>" "${CASE7_OUT}"

# Sanity check: without any project layer the fallback path normally
# resolves to one of the builtin entries (proves the skip-masked
# logic, not just an empty registry, is what closes the fallback).
rm -f "${PROJECT_ROOT}/.cap/skills.yaml"
CASE7_BASELINE="$(layered_run "
fb = binder._find_fallback(binder.load_skill_registry(), 'frontend_implementation')
print('fallback=' + (fb['skill_id'] if fb else '<none>'))
")"
assert_contains "case7: baseline (no mask) does pick a builtin fallback" \
  "fallback=" "${CASE7_BASELINE}"
case "${CASE7_BASELINE}" in
  *"fallback=<none>"*)
    echo "  FAIL: case7 baseline returned no fallback — fixture inconsistent"
    fail_count=$((fail_count + 1)) ;;
  *)
    echo "  PASS: case7 baseline returns a real fallback (skip-masked logic isolated)"
    pass_count=$((pass_count + 1)) ;;
esac

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
