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

capture() {
  local rc=0
  local out
  out="$("${CAP_ENTRY}" "$@" 2>&1)" || rc=$?
  printf '%s\t%s\n' "${rc}" "${out}"
}

assert_same_command() {
  local label="$1"
  local canonical="$2"
  local alias="$3"
  shift 3

  local expected actual
  expected="$(capture "${canonical}" "$@")"
  actual="$(capture "${alias}" "$@")"
  assert_eq "${label}" "${expected}" "${actual}"
}

assert_same_command "cap p init --help equals cap project init --help" project p init --help
assert_same_command "cap proj init --help equals cap project init --help" project proj init --help
assert_same_command "cap wf list equals cap workflow list" workflow wf list
assert_same_command "cap prov doctor --help equals cap provider doctor --help" provider prov doctor --help
assert_same_command "cap -h equals cap help" help -h
assert_same_command "cap --help equals cap help" help --help
assert_same_command "cap -v equals cap version" version -v
assert_same_command "cap --version equals cap version" version --version

provider_alias="$(capture prov doctor --help)"
provider_alias_rc="${provider_alias%%$'\t'*}"
provider_alias_out="${provider_alias#*$'\t'}"
assert_eq "cap prov doctor --help exits 0" "0" "${provider_alias_rc}"
assert_contains "provider alias keeps provider doctor wording" "Usage: cap provider doctor" "${provider_alias_out}"

project_alias="$(capture p init --help)"
project_alias_rc="${project_alias%%$'\t'*}"
project_alias_out="${project_alias#*$'\t'}"
assert_eq "cap p init --help exits 0" "0" "${project_alias_rc}"
assert_contains "project alias keeps project usage" "Usage: cap project" "${project_alias_out}"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
