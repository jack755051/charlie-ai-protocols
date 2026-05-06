#!/usr/bin/env bash
#
# test-bootstrap-constitution-defaults-exit-code.sh — assert that
# bootstrap-constitution-defaults.sh halts with exit 41 (schema_validation_failed)
# when its required schema or capabilities files are missing. Per
# policies/workflow-executor-exit-codes.md this script is schema-class.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_SCRIPT="${REPO_ROOT}/scripts/workflows/bootstrap-constitution-defaults.sh"

[ -x "${BOOTSTRAP_SCRIPT}" ] || { echo "FAIL: bootstrap-constitution-defaults.sh not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-bootstrap-test.XXXXXX)"
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

# Stage a fake CAP_ROOT under sandbox missing the schema files.
FAKE_ROOT="${SANDBOX}/fake-cap-root"
mkdir -p "${FAKE_ROOT}/schemas"
# Intentionally do NOT create project-constitution.schema.yaml — bootstrap
# should halt with schema_missing.

echo "Case 1: project-constitution.schema.yaml missing → exit 41"
out="$(CAP_ROOT="${FAKE_ROOT}" bash "${BOOTSTRAP_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 (schema_validation_failed) on schema_missing" "41" "${rc}"
assert_contains "reason: schema_missing" "schema_missing" "${out}"

echo "Case 2: schemas/capabilities.yaml missing → exit 41"
# Provide schema but not capabilities
touch "${FAKE_ROOT}/schemas/project-constitution.schema.yaml"
out="$(CAP_ROOT="${FAKE_ROOT}" bash "${BOOTSTRAP_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 on capabilities_missing" "41" "${rc}"
assert_contains "reason: capabilities_missing" "capabilities_missing" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
