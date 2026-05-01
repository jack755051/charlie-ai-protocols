#!/usr/bin/env bash
#
# test-persist-constitution-exit-code.sh — assert that persist-constitution.sh
# halts with exit 41 (schema_validation_failed) when given missing or invalid
# inputs. Per policies/workflow-executor-exit-codes.md this script is
# schema-class so all failures (including filesystem write failures inside
# its own scope) must surface as exit 41.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PERSIST_SCRIPT="${REPO_ROOT}/scripts/workflows/persist-constitution.sh"

[ -x "${PERSIST_SCRIPT}" ] || { echo "FAIL: persist-constitution.sh not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-persist-cons-test.XXXXXX)"
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

# Case 1: empty input context → missing_draft_artifact → exit 41
echo "Case 1: missing draft artifact in input context"
out="$(CAP_HOME="${SANDBOX}/cap" CAP_WORKFLOW_INPUT_CONTEXT="" bash "${PERSIST_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 (schema_validation_failed) on missing draft artifact" "41" "${rc}"
assert_contains "reason: missing_draft_artifact" "missing_draft_artifact" "${out}"

# Case 2: upstream validation report indicating schema_validation_failed →
# upstream_validation_failed → exit 41
echo "Case 2: upstream validation failure surfaced via report"
VALIDATION_REPORT="${SANDBOX}/validation.md"
cat > "${VALIDATION_REPORT}" <<'EOF'
# validate_constitution

condition: schema_validation_failed
reason: constitution_schema_invalid
EOF
INPUT_CTX="path=${VALIDATION_REPORT} artifact=constitution_validation_report"
out="$(CAP_HOME="${SANDBOX}/cap" CAP_WORKFLOW_INPUT_CONTEXT="${INPUT_CTX}" bash "${PERSIST_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 on upstream validation failure" "41" "${rc}"
assert_contains "reason: upstream_validation_failed" "upstream_validation_failed" "${out}"

# Case 3: legacy git_operation_failed string still recognized for backward compat
echo "Case 3: legacy git_operation_failed string in validation report"
LEGACY_REPORT="${SANDBOX}/legacy-validation.md"
cat > "${LEGACY_REPORT}" <<'EOF'
# validate_constitution

condition: git_operation_failed
reason: constitution_schema_invalid
EOF
INPUT_CTX_LEGACY="path=${LEGACY_REPORT} artifact=constitution_validation_report"
out="$(CAP_HOME="${SANDBOX}/cap" CAP_WORKFLOW_INPUT_CONTEXT="${INPUT_CTX_LEGACY}" bash "${PERSIST_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 on legacy git_operation_failed string" "41" "${rc}"
assert_contains "reason: upstream_validation_failed (legacy)" "upstream_validation_failed" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
