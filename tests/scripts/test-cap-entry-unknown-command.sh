#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

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

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass
  else
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if grep -Fq "${needle}" <<<"${haystack}"; then
    pass
  else
    fail "${label}: missing '${needle}'"
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if grep -Fq "${needle}" <<<"${haystack}"; then
    fail "${label}: unexpectedly found '${needle}'"
  else
    pass
  fi
}

run_unknown() {
  local command="$1"
  local out
  local rc=0
  out="$("${CAP_ENTRY}" "${command}" 2>&1)" || rc=$?
  printf '%s\t%s\n' "${rc}" "${out}"
}

result_list="$(run_unknown list)"
rc_list="${result_list%%$'\t'*}"
out_list="${result_list#*$'\t'}"

assert_eq "cap list exits 1" "1" "${rc_list}"
assert_contains "cap list reports unknown" "Unknown cap command: list" "${out_list}"
assert_contains "cap list points to help" "cap help" "${out_list}"
assert_not_contains "cap list no removed reminder" "cap list has been removed" "${out_list}"
assert_not_contains "cap list no skill suggestion" "cap skill list" "${out_list}"
assert_not_contains "cap list no workflow suggestion" "cap workflow list" "${out_list}"

result_bad="$(run_unknown does-not-exist)"
rc_bad="${result_bad%%$'\t'*}"
out_bad="${result_bad#*$'\t'}"

assert_eq "unknown command exits 1" "1" "${rc_bad}"
assert_contains "unknown command reports command" "Unknown cap command: does-not-exist" "${out_bad}"
assert_contains "unknown command points to help" "cap help" "${out_bad}"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
