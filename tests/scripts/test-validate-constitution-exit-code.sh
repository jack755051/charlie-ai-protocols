#!/usr/bin/env bash
#
# test-validate-constitution-exit-code.sh — assert that validate-constitution.sh
# halts with exit 41 (schema_validation_failed) when given an artifact missing
# the required JSON block. Per policies/workflow-executor-exit-codes.md the
# script is schema-class so all failures must surface as exit 41.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALIDATE_SCRIPT="${REPO_ROOT}/scripts/workflows/validate-constitution.sh"

[ -x "${VALIDATE_SCRIPT}" ] || { echo "FAIL: validate-constitution.sh not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-validate-test.XXXXXX)"
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
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# Case 1: artifact has no JSON block at all → no_constitution_json_block → exit 41
echo "Case 1: artifact missing both explicit fence and \`\`\`json block"
DRAFT_PATH="${SANDBOX}/no-json.md"
cat > "${DRAFT_PATH}" <<'EOF'
# No JSON Block Here

This artifact has prose only and no constitution JSON block.
EOF

INPUT_CTX="path=${DRAFT_PATH} artifact=project_constitution"
out="$(CAP_WORKFLOW_INPUT_CONTEXT="${INPUT_CTX}" bash "${VALIDATE_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 (schema_validation_failed) on missing JSON block" "41" "${rc}"
assert_contains "reason: no_constitution_json_block" "no_constitution_json_block" "${out}"

# Case 2: missing draft artifact entirely → missing_draft_artifact → exit 41
echo "Case 2: input context has no resolvable artifact path"
out="$(CAP_WORKFLOW_INPUT_CONTEXT="" bash "${VALIDATE_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 on missing draft artifact" "41" "${rc}"
assert_contains "reason: missing_draft_artifact" "missing_draft_artifact" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
