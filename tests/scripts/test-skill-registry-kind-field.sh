#!/usr/bin/env bash
#
# test-skill-registry-kind-field.sh — Role/Skill Registry Phase 1
# focused test (v0.24.7+ schema preparation step).
#
# Verifies the optional ``kind`` enum added to
# schemas/skill-registry.schema.yaml is non-breaking:
#   * Entries with kind=role load and preserve the field.
#   * Entries with kind=skill load and preserve the field.
#   * Legacy entries without kind load unchanged (backwards-compatible).
#   * Mixing all three in the same registry produces the expected
#     three skill_ids visible to RuntimeBinder.load_skill_registry.
#
# Phase 1 is schema-only — the runtime does NOT branch on kind yet, so
# this fixture deliberately does NOT assert any behaviour change.
# It only confirms:
#   1. RuntimeBinder.load_skill_registry doesn't reject unknown keys.
#   2. The kind value round-trips into the loaded dict so future
#      runtime work can switch on it.
#   3. The legacy inference rule documented in the schema (agent_alias
#      present → role; absent → skill) is observable from a loaded
#      entry without runtime support.
#
# Reference SSOT:
#   - schemas/skill-registry.schema.yaml (kind field + legacy rule)
#   - engine/runtime_binder.py (load path, no kind branching today)
#
# Sandbox layout mirrors test-skill-registry-override.sh: explicit
# project_root / cap_home / base_dir kwargs to RuntimeBinder so the
# fixture stays isolated from the live cap-protocols repo and the
# user's real ~/.cap/shared.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${REPO_ROOT}/engine/runtime_binder.py" ] || {
  echo "FAIL: engine/runtime_binder.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-skill-registry-kind-test.XXXXXX)"
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

# Builtin layer: legacy entry without kind. agent_alias present, so the
# documented inference rule says this is implicitly kind=role.
cat > "${BUILTIN_BASE}/.cap/skills.yaml" <<'EOF'
schema_version: 2
skills:
  - skill_id: builtin-legacy-role
    skill_version: "1.0.0"
    agent_alias: legacy-role
    cli: claude
    enabled: true
    priority: 100
    prompt_file: legacy-role-agent.md
    provided_capabilities:
      - legacy_capability
EOF

# Shared layer: two entries with explicit kind discriminators.
cat > "${CAP_HOME_DIR}/shared/skills.yaml" <<'EOF'
schema_version: 2
skills:
  - skill_id: shared-explicit-role
    skill_version: "0.1.0"
    kind: role
    agent_alias: explicit-role
    cli: claude
    enabled: true
    priority: 90
    prompt_file: skills/explicit-role.md
    provided_capabilities:
      - explicit_role_capability

  - skill_id: shared-explicit-skill
    skill_version: "0.1.0"
    kind: skill
    agent_alias: explicit-skill
    cli: claude
    enabled: true
    priority: 90
    prompt_file: skills/explicit-skill.md
    provided_capabilities:
      - explicit_skill_capability
EOF

# Project layer: empty (no skills.yaml). RuntimeBinder still needs the
# directory to exist for the layered loader to consider it.

# ── Helper: query loaded registry via Python ──────────────────────────

# Prints a mini-Python-managed JSON dump of the merged registry's skills
# array (just the fields we care to assert about).
loaded_skills_json() {
  PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
      "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${BUILTIN_BASE}" <<'PY'
import json, sys
from pathlib import Path
from engine.runtime_binder import RuntimeBinder

project_root, cap_home_dir, builtin_base = sys.argv[1:4]
binder = RuntimeBinder(
    base_dir=Path(builtin_base),
    project_root=Path(project_root),
    cap_home=Path(cap_home_dir),
)
reg = binder.load_skill_registry()
slim = []
for entry in reg.get("skills", []):
    slim.append({
        "skill_id": entry.get("skill_id"),
        "kind": entry.get("kind"),                 # may be missing
        "agent_alias": entry.get("agent_alias"),   # may be missing
        "_source_layer": entry.get("_source_layer"),
        "_inferred_kind": (
            entry.get("kind")
            or ("role" if entry.get("agent_alias") else "skill")
        ),
    })
print(json.dumps(slim))
PY
}

OUT="$(loaded_skills_json 2>&1)"
LOAD_RC=$?

assert_eq "1. RuntimeBinder.load_skill_registry exits 0 with kind field present" \
  "0" "${LOAD_RC}"

# All three entries should appear in the merged registry.
assert_contains "2a. legacy entry (no kind) loads"     "builtin-legacy-role"   "${OUT}"
assert_contains "2b. kind=role entry loads"            "shared-explicit-role"  "${OUT}"
assert_contains "2c. kind=skill entry loads"           "shared-explicit-skill" "${OUT}"

# Source-layer attribution stays correct after the schema addition.
assert_contains "3a. legacy entry stays in builtin layer" \
  '"skill_id": "builtin-legacy-role", "kind": null, "agent_alias": "legacy-role", "_source_layer": "builtin"' \
  "${OUT}"
assert_contains "3b. kind=role entry tagged shared" \
  '"skill_id": "shared-explicit-role", "kind": "role", "agent_alias": "explicit-role", "_source_layer": "shared"' \
  "${OUT}"
assert_contains "3c. kind=skill entry tagged shared" \
  '"skill_id": "shared-explicit-skill", "kind": "skill", "agent_alias": "explicit-skill", "_source_layer": "shared"' \
  "${OUT}"

# Legacy compat inference (agent_alias present → role) is observable on
# the loaded dict via the explicit fallback we computed in Python.
# Real runtime today does NOT use _inferred_kind — it's the hand-rolled
# proxy for the rule documented in skill-registry.schema.yaml. This
# assertion locks the rule semantics in place so when the runtime
# eventually consults kind, the behaviour matches the doc.
assert_contains "4a. legacy entry inferred as role (agent_alias present)" \
  '"_inferred_kind": "role"' "${OUT}"
# All three entries here have agent_alias today (because RuntimeBinder
# requires it to satisfy _has_execution_metadata when selected). The
# explicit kind=skill entry still infers as role under the agent_alias-
# presence rule, which is fine — explicit kind beats inference, and
# the loaded dict shows the explicit value:
explicit_skill_kind="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.argv[1])
print([e["kind"] for e in data if e["skill_id"] == "shared-explicit-skill"][0])
' "${OUT}")"
assert_eq "4b. explicit kind=skill wins over agent_alias-based inference" \
  "skill" "${explicit_skill_kind}"

# Phase 1 boundary: confirm the runtime did NOT branch on kind. The
# easiest signal is that all three entries are still selectable
# candidates if their capability is asked for — i.e. kind doesn't
# silently exclude an entry from candidacy.
candidate_count="$(PYTHONPATH="${REPO_ROOT}" "${PYTHON_BIN}" - \
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
# _find_candidates is the function bind_semantic_plan uses; calling it
# directly with the three capabilities our fixture entries provide
# confirms each entry is still considered.
caps = [
    ("legacy_capability",        "builtin-legacy-role"),
    ("explicit_role_capability", "shared-explicit-role"),
    ("explicit_skill_capability","shared-explicit-skill"),
]
seen = 0
for cap, expected_skill_id in caps:
    cands = binder._find_candidates(reg, cap, workflow_version=1)
    if any(c.get("skill_id") == expected_skill_id for c in cands):
        seen += 1
print(seen)
PY
)"

assert_eq "5. all three entries remain selectable candidates (kind doesn't exclude)" \
  "3" "${candidate_count}"

echo ""
total=$((pass_count + fail_count))
echo "skill-registry-kind-field: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
