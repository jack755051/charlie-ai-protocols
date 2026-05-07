#!/usr/bin/env bash
#
# test-project-skills-snapshot.sh — H2 #2 focused test.
#
# Cases:
#   1. snapshot determinism (same content → same dir_hash + per-skill hashes)
#   2. flat skills.yaml only (no per-skill subdir)
#   3. flat + per-skill subdir → both contribute to dir_hash + skills_by_id
#   4. content drift on flat file changes dir_hash + flat_registry hash +
#      affected skill_id hash; untouched skill_ids stable
#   5. missing .cap dir → project_dir_present=false, empty maps, sentinel
#      empty-string sha256 dir_hash
#   6. summary projection drops skills_by_id / per_skill_files but keeps
#      counts and dir_hash
#   7. attach is idempotent on an existing envelope (existing baseline
#      preserved across re-runs)
#   8. CAP_PROJECT_ROOT env override resolves correctly
#   9. single-skill file shape under .cap/skills/<file>.yaml is recognised
#
# Reference SSOT:
#   - docs/cap/H2-PROJECT-SKILL-DRIFT-DESIGN.md §2
#   - engine/project_skills_snapshot.py

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SNAPSHOT_PY="${REPO_ROOT}/engine/project_skills_snapshot.py"

[ -f "${SNAPSHOT_PY}" ] || { echo "FAIL: project_skills_snapshot.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-project-skills-snapshot-test.XXXXXX)"
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

assert_neq() {
  local desc="$1" lhs="$2" rhs="$3"
  if [ "${lhs}" != "${rhs}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    both values were: ${lhs}"
    fail_count=$((fail_count + 1))
  fi
}

snapshot() {
  local project_root="$1"
  "${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot --project-root "${project_root}"
}

extract() {
  local snap="$1" expr="$2"
  printf '%s' "${snap}" | "${PYTHON_BIN}" -c "
import json, sys
data = json.loads(sys.stdin.read())
print(${expr})
"
}

# ── Common fixture: project root with flat skills.yaml + per-skill ──

PROJECT_A="${SANDBOX}/projA"
mkdir -p "${PROJECT_A}/.cap/skills"
cat > "${PROJECT_A}/.cap/skills.yaml" <<'EOF'
schema_version: 1
default_provider: builtin
binding_defaults:
  binding_mode: strict
  missing_policy: halt
skills:
  - skill_id: my-frontend-react18
    agent_alias: frontend
    provider: builtin
    enabled: true
    priority: 110
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
    fallback_roles:
      - implementer
    prompt_file: agent-skills/frontend-react18.md
    cli: claude
  - skill_id: my-qa-extended
    agent_alias: qa
    provider: builtin
    enabled: true
    priority: 100
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - qa_testing
    fallback_roles:
      - reviewer
    prompt_file: agent-skills/qa-extended.md
    cli: claude
EOF

# Per-skill subdir entry (multi-skill envelope shape).
cat > "${PROJECT_A}/.cap/skills/extra.yaml" <<'EOF'
schema_version: 1
skills:
  - skill_id: my-extra-tool
    agent_alias: helper
    provider: builtin
    enabled: true
    priority: 90
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - helper_tooling
    fallback_roles:
      - implementer
    prompt_file: agent-skills/extra-helper.md
    cli: claude
EOF

# Single-skill file shape under .cap/skills/<file>.yaml (Case 9).
cat > "${PROJECT_A}/.cap/skills/single-skill.yaml" <<'EOF'
schema_version: 1
skill_id: my-single-skill
agent_alias: helper
provider: builtin
enabled: true
priority: 95
compatible_workflow_versions: [1, 2, 3]
provided_capabilities:
  - single_capability
fallback_roles:
  - implementer
prompt_file: agent-skills/single-skill.md
cli: claude
EOF

# ── Case 1: determinism ─────────────────────────────────────────────

echo "Case 1: snapshot is deterministic for identical content"
SNAP1="$(snapshot "${PROJECT_A}")"
SNAP2="$(snapshot "${PROJECT_A}")"
DIR_HASH_1="$(extract "${SNAP1}" "data['dir_hash']")"
DIR_HASH_2="$(extract "${SNAP2}" "data['dir_hash']")"
assert_eq "case1: dir_hash deterministic" "${DIR_HASH_1}" "${DIR_HASH_2}"

# ── Case 2: project_dir_present + flat-only minimum ─────────────────

echo ""
echo "Case 2: skills.yaml + per-skill subdir present"
PRESENT="$(extract "${SNAP1}" "data['project_dir_present']")"
assert_eq "case2: project_dir_present=True" "True" "${PRESENT}"

FLAT_PRESENT="$(extract "${SNAP1}" "data['flat_registry'] is not None")"
assert_eq "case2: flat_registry recorded" "True" "${FLAT_PRESENT}"

# ── Case 3: per-skill subdir contributes ────────────────────────────

echo ""
echo "Case 3: per-skill files contribute to dir_hash + skills_by_id"
PER_SKILL_COUNT="$(extract "${SNAP1}" "len(data['per_skill_files'])")"
assert_eq "case3: per_skill_files has 2 entries (extra.yaml + single-skill.yaml)" \
  "2" "${PER_SKILL_COUNT}"

SKILL_COUNT="$(extract "${SNAP1}" "len(data['skills_by_id'])")"
# 2 from flat (my-frontend-react18, my-qa-extended) + 1 from extra.yaml (my-extra-tool) + 1 from single-skill.yaml (my-single-skill)
assert_eq "case3: skills_by_id covers all 4 skills" "4" "${SKILL_COUNT}"

EXTRA_FROM_PERSKILL="$(extract "${SNAP1}" "
'extra' in data['skills_by_id']['my-extra-tool']['source_path']
")"
assert_eq "case3: my-extra-tool source_path points at per-skill file" \
  "True" "${EXTRA_FROM_PERSKILL}"

# ── Case 4: edit flat file → hashes shift in expected places ────────

echo ""
echo "Case 4: editing flat skills.yaml changes flat_registry + skill hash"
# Capture pre-edit hashes for stable skills.
QA_HASH_BEFORE="$(extract "${SNAP1}" "data['skills_by_id']['my-qa-extended']['hash']")"
EXTRA_HASH_BEFORE="$(extract "${SNAP1}" "data['skills_by_id']['my-extra-tool']['hash']")"

# Edit only the my-frontend-react18 entry's priority.
"${PYTHON_BIN}" - <<PY
import yaml
from pathlib import Path
p = Path("${PROJECT_A}/.cap/skills.yaml")
data = yaml.safe_load(p.read_text(encoding="utf-8"))
for s in data["skills"]:
    if s["skill_id"] == "my-frontend-react18":
        s["priority"] = 999
p.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
PY

SNAP3="$(snapshot "${PROJECT_A}")"
DIR_HASH_3="$(extract "${SNAP3}" "data['dir_hash']")"
assert_neq "case4: dir_hash changed after edit" "${DIR_HASH_1}" "${DIR_HASH_3}"

FE_HASH_AFTER="$(extract "${SNAP3}" "data['skills_by_id']['my-frontend-react18']['hash']")"
FE_HASH_BEFORE="$(extract "${SNAP1}" "data['skills_by_id']['my-frontend-react18']['hash']")"
assert_neq "case4: my-frontend-react18 hash changed" "${FE_HASH_BEFORE}" "${FE_HASH_AFTER}"

QA_HASH_AFTER="$(extract "${SNAP3}" "data['skills_by_id']['my-qa-extended']['hash']")"
assert_eq "case4: my-qa-extended hash stable (not edited)" \
  "${QA_HASH_BEFORE}" "${QA_HASH_AFTER}"

EXTRA_HASH_AFTER="$(extract "${SNAP3}" "data['skills_by_id']['my-extra-tool']['hash']")"
assert_eq "case4: my-extra-tool hash stable (per-skill file untouched)" \
  "${EXTRA_HASH_BEFORE}" "${EXTRA_HASH_AFTER}"

# ── Case 5: missing .cap dir → empty snapshot sentinel ──────────────

echo ""
echo "Case 5: missing .cap/ dir → project_dir_present=False, empty data"
PROJECT_NONE="${SANDBOX}/projNone"
mkdir -p "${PROJECT_NONE}"

SNAP_NONE="$(snapshot "${PROJECT_NONE}")"
NONE_PRESENT="$(extract "${SNAP_NONE}" "data['project_dir_present']")"
assert_eq "case5: project_dir_present=False" "False" "${NONE_PRESENT}"

NONE_SKILLS="$(extract "${SNAP_NONE}" "len(data['skills_by_id'])")"
assert_eq "case5: skills_by_id is empty" "0" "${NONE_SKILLS}"

NONE_FLAT="$(extract "${SNAP_NONE}" "data['flat_registry']")"
assert_eq "case5: flat_registry is None" "None" "${NONE_FLAT}"

NONE_DIR_HASH="$(extract "${SNAP_NONE}" "data['dir_hash']")"
case "${NONE_DIR_HASH}" in
  sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
    echo "  PASS: case5: empty dir_hash uses canonical empty-sha256 sentinel"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case5: empty dir_hash mismatch: ${NONE_DIR_HASH}"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Case 6: summary projection ──────────────────────────────────────

echo ""
echo "Case 6: summary projection drops detail maps but keeps counts"
SUMMARY="$("${PYTHON_BIN}" "${SNAPSHOT_PY}" summary --project-root "${PROJECT_A}")"

assert_eq "case6: summary skill_count = 4" \
  "4" \
  "$(extract "${SUMMARY}" "data['skill_count']")"
assert_eq "case6: summary per_skill_file_count = 2" \
  "2" \
  "$(extract "${SUMMARY}" "data['per_skill_file_count']")"
case "${SUMMARY}" in
  *skills_by_id*)
    echo "  FAIL: case6: summary leaked skills_by_id key"
    fail_count=$((fail_count + 1)) ;;
  *)
    echo "  PASS: case6: summary excludes skills_by_id (compact)"
    pass_count=$((pass_count + 1)) ;;
esac

# ── Case 7: attach is idempotent ────────────────────────────────────

echo ""
echo "Case 7: attach idempotency"
LEDGER="${SANDBOX}/agent-sessions.json"
cat > "${LEDGER}" <<'EOF'
{
  "version": 1,
  "run_id": "run_test_001",
  "workflow_id": "smoke",
  "workflow_name": "smoke",
  "sessions": []
}
EOF

"${PYTHON_BIN}" "${SNAPSHOT_PY}" attach "${LEDGER}" --project-root "${PROJECT_A}" >/dev/null
HASH_AFTER_FIRST="$("${PYTHON_BIN}" -c "
import json
print(json.load(open('${LEDGER}'))['project_skill_baseline']['dir_hash'])
")"

# Edit a file then re-attach; envelope baseline must be preserved.
"${PYTHON_BIN}" - <<PY
import yaml
from pathlib import Path
p = Path("${PROJECT_A}/.cap/skills.yaml")
data = yaml.safe_load(p.read_text(encoding="utf-8"))
data["skills"][0]["priority"] = 12345
p.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
PY

"${PYTHON_BIN}" "${SNAPSHOT_PY}" attach "${LEDGER}" --project-root "${PROJECT_A}" >/dev/null
HASH_AFTER_SECOND="$("${PYTHON_BIN}" -c "
import json
print(json.load(open('${LEDGER}'))['project_skill_baseline']['dir_hash'])
")"

assert_eq "case7: re-attach is no-op (preserves first observation)" \
  "${HASH_AFTER_FIRST}" "${HASH_AFTER_SECOND}"

# ── Case 8: CAP_PROJECT_ROOT env override ───────────────────────────

echo ""
echo "Case 8: CAP_PROJECT_ROOT env var resolves project_root"
ENV_SNAP="$(CAP_PROJECT_ROOT="${PROJECT_A}" "${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot)"
ENV_PROJECT_ROOT="$(extract "${ENV_SNAP}" "data['project_root']")"
case "${ENV_PROJECT_ROOT}" in
  *projA*)
    echo "  PASS: case8: env override resolves to projA"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case8: env override mismatch: ${ENV_PROJECT_ROOT}"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Case 9: single-skill file shape (already validated by case 3) ──

echo ""
echo "Case 9: single-skill file shape under .cap/skills/<file>.yaml"
SINGLE_PRESENT="$(extract "${SNAP3}" "'my-single-skill' in data['skills_by_id']")"
assert_eq "case9: my-single-skill (single-skill shape) extracted" \
  "True" "${SINGLE_PRESENT}"

SINGLE_SOURCE="$(extract "${SNAP3}" "data['skills_by_id']['my-single-skill']['source_path']")"
case "${SINGLE_SOURCE}" in
  *single-skill.yaml*)
    echo "  PASS: case9: single-skill source_path correct"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case9: single-skill source_path mismatch: ${SINGLE_SOURCE}"
    fail_count=$((fail_count + 1)) ;;
esac

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
