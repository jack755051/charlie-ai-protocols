#!/usr/bin/env bash
#
# test-skill-registry-resolver.sh — P9 #3 focused test.
#
# Exercises the layered skill registry resolver implemented in
# ``engine/runtime_binder.py:RuntimeBinder.load_skill_registry``.
# Reference: docs/cap/P9-SOURCE-RESOLVER-DESIGN.md §5.
#
# Cases:
#   1. project skill same id overrides builtin
#   2. project skill new id extends builtin
#   3. shared-only skill is loaded
#   4. project beats shared (priority chain holds)
#   5. explicit registry_ref short-circuits to single-file load
#   6. cap-protocols self-mode (project_root == base_dir) collapses
#      project layer into builtin (no double-load)
#   7. binding_defaults deep-merge: project keys win at every level
#   8. _source_layer / _source_path tags attached per skill entry
#
# Drives the loader with explicit ``project_root`` / ``cap_home``
# kwargs to keep each case isolated from the live cap-protocols
# repo and the user's real ``~/.cap``.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-skill-registry-resolver-test.XXXXXX)"
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

# layered_query <python_expr> — instantiate RuntimeBinder with the
# current sandbox env (project_root / cap_home / base_dir) and print
# the value of <python_expr> evaluated against the loaded registry.
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

# write_skills <path> <yaml-body>
write_skills() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "${path}")"
  printf '%s' "${body}" > "${path}"
}

# ── Sandbox layout ────────────────────────────────────────────────────
#   ${PROJECT_ROOT}/.cap/skills.yaml          (project flat)
#   ${PROJECT_ROOT}/.cap/skills/<id>.yaml     (project per-skill)
#   ${CAP_HOME_DIR}/shared/skills.yaml        (shared flat)
#   ${BUILTIN_BASE}/.cap/skills.yaml          (builtin flat — separate
#                                              from cap-protocols' own)
#
# Builtin is staged inside the sandbox (separate from cap-protocols)
# so the binder doesn't load real cap-protocols skills.

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
BUILTIN_BASE="${SANDBOX}/builtin"
mkdir -p "${PROJECT_ROOT}/.cap" "${CAP_HOME_DIR}/shared" "${BUILTIN_BASE}/.cap"

# Common builtin registry used by Cases 1-4.
write_skills "${BUILTIN_BASE}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: builtin
binding_defaults:
  binding_mode: strict
  missing_policy: halt
  defaults:
    timeout_seconds: 600
    fallback_provider: codex
skills:
  - skill_id: shared-skill
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: builtin-shared
    prompt_file: agent-skills/00-core-protocol.md
    cli: codex
  - skill_id: only-builtin
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: builtin-only
    prompt_file: agent-skills/00-core-protocol.md
    cli: codex
EOF
)"

# ── Case 1: project skill same id overrides builtin ──────────────────

echo "Case 1: project skill same id overrides builtin"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: project
skills:
  - skill_id: shared-skill
    provider: project
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: project-override
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
)"

assert_eq "case1: shared-skill provider=project (override)" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-skill'][0]['provider']")"
assert_eq "case1: shared-skill _source_layer=project" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-skill'][0]['_source_layer']")"
assert_eq "case1: only-builtin still present from builtin" "builtin" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='only-builtin'][0]['_source_layer']")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 2: project skill new id extends builtin ─────────────────────

echo ""
echo "Case 2: project skill new id extends builtin"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: project
skills:
  - skill_id: project-only-skill
    provider: project
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: project-extend
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
)"

assert_eq "case2: project-only-skill present" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='project-only-skill'][0]['_source_layer']")"
assert_eq "case2: builtin shared-skill still present" "builtin" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-skill'][0]['_source_layer']")"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 3: shared-only skill is loaded ──────────────────────────────

echo ""
echo "Case 3: shared-only skill is loaded"
write_skills "${CAP_HOME_DIR}/shared/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: shared
skills:
  - skill_id: shared-cross-repo
    provider: shared
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: shared-only
    prompt_file: agent-skills/00-core-protocol.md
    cli: codex
EOF
)"

assert_eq "case3: shared-cross-repo _source_layer=shared" "shared" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-cross-repo'][0]['_source_layer']")"

# ── Case 4: project beats shared ─────────────────────────────────────

echo ""
echo "Case 4: project beats shared (priority chain)"
# shared keeps the same shared-cross-repo skill; project layer overrides.
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: project
skills:
  - skill_id: shared-cross-repo
    provider: project
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: project-beats-shared
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
)"

assert_eq "case4: shared-cross-repo provider=project (override)" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-cross-repo'][0]['provider']")"
assert_eq "case4: shared-cross-repo _source_layer=project" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='shared-cross-repo'][0]['_source_layer']")"

# Cleanup for next case.
rm -f "${PROJECT_ROOT}/.cap/skills.yaml" "${CAP_HOME_DIR}/shared/skills.yaml"

# ── Case 5: explicit registry_ref short-circuits ─────────────────────

echo ""
echo "Case 5: explicit registry_ref short-circuits to single-file load"
EXPLICIT_FILE="${SANDBOX}/elsewhere/explicit-skills.yaml"
write_skills "${EXPLICIT_FILE}" "$(cat <<'EOF'
schema_version: 1
default_provider: explicit
skills:
  - skill_id: explicit-only
    provider: explicit
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: explicit-test
    prompt_file: agent-skills/00-core-protocol.md
    cli: codex
EOF
)"

EXPLICIT_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${EXPLICIT_FILE}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

builtin_base, project_root, cap_home_dir, explicit = sys.argv[1:5]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry(registry_ref=explicit)
ids = [s["skill_id"] for s in reg.get("skills", [])]
print("ids=" + ",".join(ids))
print("source_path=" + reg.get("_source_path", ""))
print("has_source_paths=" + str("_source_paths" in reg))
PY
)"

# Single-file load: only explicit-only present (no builtin merge).
case "${EXPLICIT_OUT}" in
  *"ids=explicit-only"*)
    echo "  PASS: case5: only explicit-only loaded (no merge)"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case5: expected only explicit-only"
    echo "    out: ${EXPLICIT_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac
case "${EXPLICIT_OUT}" in
  *"source_path=${EXPLICIT_FILE}"*)
    echo "  PASS: case5: _source_path = explicit file"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case5: _source_path mismatch"
    echo "    out: ${EXPLICIT_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac
case "${EXPLICIT_OUT}" in
  *"has_source_paths=False"*)
    echo "  PASS: case5: no _source_paths (single-file path)"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case5: _source_paths leaked into single-file mode"
    echo "    out: ${EXPLICIT_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Case 6: self-mode (project_root == base_dir) does not double-load ─

echo ""
echo "Case 6: self-mode collapses project layer (no double-load)"
SELF_BASE="${SANDBOX}/self_mode"
mkdir -p "${SELF_BASE}/.cap"
write_skills "${SELF_BASE}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
default_provider: builtin
skills:
  - skill_id: self-mode-skill
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: self-mode
    prompt_file: agent-skills/00-core-protocol.md
    cli: codex
EOF
)"

SELF_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${SELF_BASE}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

base = sys.argv[1]
binder = RuntimeBinder(
    base_dir=Path(base),
    project_root=Path(base),  # explicit same path == self-mode
    cap_home=Path(base),
)
reg = binder.load_skill_registry()
matches = [s for s in reg["skills"] if s["skill_id"] == "self-mode-skill"]
print("count=" + str(len(matches)))
if matches:
    print("layer=" + matches[0]["_source_layer"])
PY
)"

case "${SELF_OUT}" in
  *"count=1"*)
    echo "  PASS: case6: self-mode-skill not duplicated"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case6: self-mode duplicate detected"
    echo "    out: ${SELF_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac
case "${SELF_OUT}" in
  *"layer=builtin"*)
    echo "  PASS: case6: self-mode skill tagged builtin"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case6: self-mode layer expected builtin"
    echo "    out: ${SELF_OUT}"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Case 7: binding_defaults deep-merge ──────────────────────────────

echo ""
echo "Case 7: binding_defaults deep-merge — project keys win at every level"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<'EOF'
schema_version: 1
binding_defaults:
  binding_mode: strict
  defaults:
    timeout_seconds: 30
    project_only: "yes"
skills:
  - skill_id: project-defaults-only
    provider: project
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: defaults-test
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
)"

DEFAULTS_OUT="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - "${BUILTIN_BASE}" "${PROJECT_ROOT}" "${CAP_HOME_DIR}" <<'PY'
import sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

builtin, project, cap_home = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin),
    project_root=Path(project),
    cap_home=Path(cap_home),
)
reg = binder.load_skill_registry()
bd = reg.get("binding_defaults", {})
defaults = bd.get("defaults", {}) or {}
print(f"binding_mode={bd.get('binding_mode')}")
print(f"missing_policy={bd.get('missing_policy')}")  # only builtin had this
print(f"timeout_seconds={defaults.get('timeout_seconds')}")  # project wins (30)
print(f"fallback_provider={defaults.get('fallback_provider')}")  # only builtin had this
print(f"project_only={defaults.get('project_only')}")
PY
)"

assert_eq "case7: project binding_mode wins (strict)" \
  "binding_mode=strict" \
  "$(printf '%s\n' "${DEFAULTS_OUT}" | grep '^binding_mode=')"
assert_eq "case7: builtin missing_policy preserved (halt)" \
  "missing_policy=halt" \
  "$(printf '%s\n' "${DEFAULTS_OUT}" | grep '^missing_policy=')"
assert_eq "case7: project timeout_seconds wins (30)" \
  "timeout_seconds=30" \
  "$(printf '%s\n' "${DEFAULTS_OUT}" | grep '^timeout_seconds=')"
assert_eq "case7: builtin fallback_provider preserved" \
  "fallback_provider=codex" \
  "$(printf '%s\n' "${DEFAULTS_OUT}" | grep '^fallback_provider=')"
assert_eq "case7: project_only key added" \
  "project_only=yes" \
  "$(printf '%s\n' "${DEFAULTS_OUT}" | grep '^project_only=')"

rm -f "${PROJECT_ROOT}/.cap/skills.yaml"

# ── Case 8: _source_layer / _source_path tags on every skill ─────────

echo ""
echo "Case 8: _source_layer + _source_path tags on every skill entry"
write_skills "${PROJECT_ROOT}/.cap/skills.yaml" "$(cat <<EOF
schema_version: 1
skills:
  - skill_id: tagged-project
    provider: project
    enabled: true
    priority: 100
    compatible_workflow_versions: []
    provided_capabilities: []
    fallback_roles: []
    agent_alias: tags-test
    prompt_file: agent-skills/00-core-protocol.md
    cli: claude
EOF
)"

assert_eq "case8: project _source_layer tagged" "project" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='tagged-project'][0]['_source_layer']")"
assert_eq "case8: project _source_path tagged" \
  "${PROJECT_ROOT}/.cap/skills.yaml" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='tagged-project'][0]['_source_path']")"
assert_eq "case8: builtin _source_layer tagged" "builtin" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='only-builtin'][0]['_source_layer']")"
assert_eq "case8: builtin _source_path tagged" \
  "${BUILTIN_BASE}/.cap/skills.yaml" \
  "$(layered_query "[s for s in reg['skills'] if s['skill_id']=='only-builtin'][0]['_source_path']")"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
