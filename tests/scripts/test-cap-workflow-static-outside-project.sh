#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"

failures=0
checks=0

pass() {
  checks=$((checks + 1))
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s' "${haystack}" | grep -Fq "${needle}"; then
    pass
  else
    fail "${label}: missing ${needle}"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mkdir -p "${tmpdir}/plain"
cd "${tmpdir}/plain"

unset CAP_PROJECT_ID_OVERRIDE
unset CAP_ALLOW_BASENAME_FALLBACK

output="$("${CAP_WORKFLOW}" list 2>&1)" || {
  rc=$?
  fail "cap workflow list should work outside a CAP project (rc=${rc}); output=${output}"
  echo "Summary: $((checks - failures)) passed, ${failures} failed"
  exit 1
}

assert_contains "${output}" "WORKFLOW LIST" "workflow list header"
assert_contains "${output}" "workflow-smoke-test.yaml" "builtin workflow visible"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
