#!/usr/bin/env bash
#
# test-h3-input-snapshots.sh — H3 #2 focused tests for the three new
# whole-file-hash snapshot modules.
#
# Cases (per snapshot module: 4 cases × 3 modules = 12 grouped):
#   workflow_yaml_snapshot:
#     1. happy path: existing yaml → workflow_present=true + sha256 hash
#     2. missing yaml → workflow_present=false + content_hash=null
#     3. content drift: edit changes hash, untouched stable
#     4. attach idempotent on envelope
#
#   constitution_snapshot:
#     5. happy path: existing constitution → constitution_present=true
#     6. missing constitution → constitution_present=false + null hash
#     7. CAP_PROJECT_ROOT env override
#     8. attach idempotent
#
#   capability_schema_snapshot:
#     9. happy path against sandbox cap_root
#     10. missing schema → schema_present=false
#     11. CAP_ROOT env override
#     12. attach idempotent
#
# Reference SSOT:
#   - docs/cap/H3-DRIFT-EXPANSION-DESIGN.md §5

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

WF_PY="${REPO_ROOT}/engine/workflow_yaml_snapshot.py"
CONST_PY="${REPO_ROOT}/engine/constitution_snapshot.py"
CAP_PY="${REPO_ROOT}/engine/capability_schema_snapshot.py"

[ -f "${WF_PY}"   ] || { echo "FAIL: workflow_yaml_snapshot.py missing"; exit 1; }
[ -f "${CONST_PY}" ] || { echo "FAIL: constitution_snapshot.py missing"; exit 1; }
[ -f "${CAP_PY}"  ] || { echo "FAIL: capability_schema_snapshot.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-h3-input-snapshots-test.XXXXXX)"
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

extract_field() {
  local snapshot_json="$1" field="$2"
  printf '%s' "${snapshot_json}" | "${PYTHON_BIN}" -c "
import json, sys
print(json.loads(sys.stdin.read())['${field}'])
"
}

# ── workflow_yaml_snapshot module ──────────────────────────────────

echo "Group 1: workflow_yaml_snapshot"

WF_FIXTURE="${SANDBOX}/sample-workflow.yaml"
cat > "${WF_FIXTURE}" <<'EOF'
workflow_id: sample
version: 1
steps:
  - id: dummy
    capability: test
EOF

# Case 1: happy
SNAP1="$("${PYTHON_BIN}" "${WF_PY}" snapshot "${WF_FIXTURE}" --workflow-id sample --source-layer project)"
assert_eq "case1: workflow_present=True" "True" "$(extract_field "${SNAP1}" "workflow_present")"
assert_eq "case1: workflow_id recorded" "sample" "$(extract_field "${SNAP1}" "workflow_id")"
assert_eq "case1: source_layer recorded" "project" "$(extract_field "${SNAP1}" "source_layer")"
HASH1="$(extract_field "${SNAP1}" "content_hash")"
case "${HASH1}" in
  sha256:*) echo "  PASS: case1: content_hash uses sha256: prefix"; pass_count=$((pass_count + 1)) ;;
  *)        echo "  FAIL: case1: content_hash bad: ${HASH1}";        fail_count=$((fail_count + 1)) ;;
esac

# Case 2: missing yaml
MISSING_WF="${SANDBOX}/does_not_exist.yaml"
SNAP2="$("${PYTHON_BIN}" "${WF_PY}" snapshot "${MISSING_WF}")"
assert_eq "case2: workflow_present=False" "False" "$(extract_field "${SNAP2}" "workflow_present")"
assert_eq "case2: content_hash=None" "None" "$(extract_field "${SNAP2}" "content_hash")"

# Case 3: drift
echo "# additional content" >> "${WF_FIXTURE}"
SNAP3="$("${PYTHON_BIN}" "${WF_PY}" snapshot "${WF_FIXTURE}")"
HASH3="$(extract_field "${SNAP3}" "content_hash")"
assert_neq "case3: content drift changes hash" "${HASH1}" "${HASH3}"

# Case 4: attach idempotent
LEDGER="${SANDBOX}/ledger.json"
cat > "${LEDGER}" <<'EOF'
{"version":1,"run_id":"r1","workflow_id":"sample","workflow_name":"s","sessions":[]}
EOF
"${PYTHON_BIN}" "${WF_PY}" attach "${LEDGER}" --workflow-path "${WF_FIXTURE}" --workflow-id sample > /dev/null
HASH_FIRST="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER}'))['workflow_yaml_baseline']['content_hash'])")"

# Edit then re-attach; envelope must preserve first observation.
echo "# edit after attach" >> "${WF_FIXTURE}"
"${PYTHON_BIN}" "${WF_PY}" attach "${LEDGER}" --workflow-path "${WF_FIXTURE}" --workflow-id sample > /dev/null
HASH_SECOND="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER}'))['workflow_yaml_baseline']['content_hash'])")"
assert_eq "case4: attach idempotent (hash preserved across reruns)" "${HASH_FIRST}" "${HASH_SECOND}"

# ── constitution_snapshot module ───────────────────────────────────

echo ""
echo "Group 2: constitution_snapshot"

PROJ_OK="${SANDBOX}/proj_ok"
mkdir -p "${PROJ_OK}/.cap"
cat > "${PROJ_OK}/.cap/constitution.yaml" <<'EOF'
project_id: dummy
allowed_capabilities: []
EOF

# Case 5: happy
SNAP5="$("${PYTHON_BIN}" "${CONST_PY}" snapshot --project-root "${PROJ_OK}")"
assert_eq "case5: constitution_present=True" "True" "$(extract_field "${SNAP5}" "constitution_present")"
HASH5="$(extract_field "${SNAP5}" "content_hash")"
case "${HASH5}" in
  sha256:*) echo "  PASS: case5: content_hash uses sha256: prefix"; pass_count=$((pass_count + 1)) ;;
  *)        echo "  FAIL: case5: content_hash bad"; fail_count=$((fail_count + 1)) ;;
esac

# Case 6: missing
PROJ_NONE="${SANDBOX}/proj_none"
mkdir -p "${PROJ_NONE}"
SNAP6="$("${PYTHON_BIN}" "${CONST_PY}" snapshot --project-root "${PROJ_NONE}")"
assert_eq "case6: constitution_present=False" "False" "$(extract_field "${SNAP6}" "constitution_present")"
assert_eq "case6: content_hash=None when missing" "None" "$(extract_field "${SNAP6}" "content_hash")"

# Case 7: CAP_PROJECT_ROOT env override
SNAP7="$(CAP_PROJECT_ROOT="${PROJ_OK}" "${PYTHON_BIN}" "${CONST_PY}" snapshot)"
assert_eq "case7: env override → constitution_present=True" "True" "$(extract_field "${SNAP7}" "constitution_present")"
HASH7="$(extract_field "${SNAP7}" "content_hash")"
assert_eq "case7: env override hash matches explicit kwarg" "${HASH5}" "${HASH7}"

# Case 8: attach idempotent
LEDGER2="${SANDBOX}/ledger2.json"
cat > "${LEDGER2}" <<'EOF'
{"version":1,"run_id":"r2","workflow_id":"x","workflow_name":"x","sessions":[]}
EOF
"${PYTHON_BIN}" "${CONST_PY}" attach "${LEDGER2}" --project-root "${PROJ_OK}" > /dev/null
HASH8_BEFORE="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER2}'))['constitution_baseline']['content_hash'])")"

echo "edited: 1" >> "${PROJ_OK}/.cap/constitution.yaml"
"${PYTHON_BIN}" "${CONST_PY}" attach "${LEDGER2}" --project-root "${PROJ_OK}" > /dev/null
HASH8_AFTER="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER2}'))['constitution_baseline']['content_hash'])")"
assert_eq "case8: re-attach preserves first observed hash" "${HASH8_BEFORE}" "${HASH8_AFTER}"

# ── capability_schema_snapshot module ──────────────────────────────

echo ""
echo "Group 3: capability_schema_snapshot"

# Case 9: happy with sandbox cap_root
CAP_OK="${SANDBOX}/cap_ok"
mkdir -p "${CAP_OK}/schemas"
cat > "${CAP_OK}/schemas/capabilities.yaml" <<'EOF'
schema_version: 1
capabilities:
  test_cap:
    default_agent: tester
EOF

SNAP9="$("${PYTHON_BIN}" "${CAP_PY}" snapshot --cap-root "${CAP_OK}")"
assert_eq "case9: schema_present=True" "True" "$(extract_field "${SNAP9}" "schema_present")"
HASH9="$(extract_field "${SNAP9}" "content_hash")"
case "${HASH9}" in
  sha256:*) echo "  PASS: case9: content_hash uses sha256: prefix"; pass_count=$((pass_count + 1)) ;;
  *)        echo "  FAIL: case9: content_hash bad"; fail_count=$((fail_count + 1)) ;;
esac

# Case 10: missing
CAP_NONE="${SANDBOX}/cap_none"
mkdir -p "${CAP_NONE}"
SNAP10="$("${PYTHON_BIN}" "${CAP_PY}" snapshot --cap-root "${CAP_NONE}")"
assert_eq "case10: schema_present=False" "False" "$(extract_field "${SNAP10}" "schema_present")"
assert_eq "case10: content_hash=None when missing" "None" "$(extract_field "${SNAP10}" "content_hash")"

# Case 11: CAP_ROOT env override
SNAP11="$(CAP_ROOT="${CAP_OK}" "${PYTHON_BIN}" "${CAP_PY}" snapshot)"
HASH11="$(extract_field "${SNAP11}" "content_hash")"
assert_eq "case11: env override hash matches explicit kwarg" "${HASH9}" "${HASH11}"

# Case 12: attach idempotent
LEDGER3="${SANDBOX}/ledger3.json"
cat > "${LEDGER3}" <<'EOF'
{"version":1,"run_id":"r3","workflow_id":"x","workflow_name":"x","sessions":[]}
EOF
"${PYTHON_BIN}" "${CAP_PY}" attach "${LEDGER3}" --cap-root "${CAP_OK}" > /dev/null
HASH12_BEFORE="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER3}'))['capability_schema_baseline']['content_hash'])")"

echo "  added_field: drift" >> "${CAP_OK}/schemas/capabilities.yaml"
"${PYTHON_BIN}" "${CAP_PY}" attach "${LEDGER3}" --cap-root "${CAP_OK}" > /dev/null
HASH12_AFTER="$("${PYTHON_BIN}" -c "import json; print(json.load(open('${LEDGER3}'))['capability_schema_baseline']['content_hash'])")"
assert_eq "case12: re-attach preserves first observed hash" "${HASH12_BEFORE}" "${HASH12_AFTER}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
