#!/usr/bin/env bash
#
# test-load-constitution-reconcile-inputs-exit-code.sh — assert that
# load-constitution-reconcile-inputs.sh halts with exit 41
# (schema_validation_failed) when the current constitution is missing.
# Per policies/workflow-executor-exit-codes.md this script is schema-class.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOAD_SCRIPT="${REPO_ROOT}/scripts/workflows/load-constitution-reconcile-inputs.sh"

[ -x "${LOAD_SCRIPT}" ] || { echo "FAIL: load-constitution-reconcile-inputs.sh not executable"; exit 1; }

SANDBOX="$(mktemp -d -t cap-load-reconcile-test.XXXXXX)"
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

# Stage a fake CAP_ROOT under sandbox missing .cap.constitution.yaml.
FAKE_ROOT="${SANDBOX}/fake-cap-root"
mkdir -p "${FAKE_ROOT}"
# Intentionally do NOT create .cap.constitution.yaml — load script should halt.

echo "Case 1: .cap.constitution.yaml missing → exit 41"
out="$(CAP_ROOT="${FAKE_ROOT}" bash "${LOAD_SCRIPT}" 2>&1)"
rc=$?
assert_eq "exit code 41 (schema_validation_failed) on missing_current_constitution" "41" "${rc}"
assert_contains "reason: missing_current_constitution" "missing_current_constitution" "${out}"

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ ${fail_count} -eq 0 ]
