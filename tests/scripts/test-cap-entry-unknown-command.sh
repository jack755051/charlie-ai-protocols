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
# does-not-exist is too far from any known command — must NOT trigger a
# weak suggestion (cutoff 0.6).
assert_not_contains "unknown gibberish has no suggestion" "Did you mean" "${out_bad}"

# ── Fuzzy match suggestions for typos ────────────────────────────────
result_updae="$(run_unknown updae)"
rc_updae="${result_updae%%$'\t'*}"
out_updae="${result_updae#*$'\t'}"
assert_eq "cap updae exits 1" "1" "${rc_updae}"
assert_contains "cap updae names typo" "Unknown cap command: updae" "${out_updae}"
assert_contains "cap updae suggests update" "Did you mean: cap update?" "${out_updae}"

result_hellp="$(run_unknown hellp)"
rc_hellp="${result_hellp%%$'\t'*}"
out_hellp="${result_hellp#*$'\t'}"
assert_eq "cap hellp exits 1" "1" "${rc_hellp}"
assert_contains "cap hellp suggests help" "Did you mean: cap help?" "${out_hellp}"

result_wofkflow="$(run_unknown wofkflow)"
rc_wofkflow="${result_wofkflow%%$'\t'*}"
out_wofkflow="${result_wofkflow#*$'\t'}"
assert_contains "cap wofkflow suggests workflow" "Did you mean: cap workflow?" "${out_wofkflow}"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
