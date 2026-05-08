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

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -Fq "${needle}"; then
    pass
  else
    fail "${label}: missing '${needle}'"
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -Fq "${needle}"; then
    fail "${label}: unexpectedly found '${needle}'"
  else
    pass
  fi
}

main_help="$("${CAP_ENTRY}" help)"
advanced_help="$("${CAP_ENTRY}" help --advanced)"

assert_contains "main help title" "常用指令" "${main_help}"
assert_contains "main help advertises advanced" "cap help --advanced" "${main_help}"
assert_contains "main help keeps workflow list" "cap workflow list" "${main_help}"
assert_contains "main help keeps project init" "cap project init" "${main_help}"
assert_contains "main help keeps typed promote" "cap promote inspect <id>" "${main_help}"

assert_not_contains "main help hides setup" "cap setup" "${main_help}"
assert_not_contains "main help hides sync" "cap sync" "${main_help}"
assert_not_contains "main help hides paths" "cap paths" "${main_help}"
assert_not_contains "main help hides task planned" "cap task plan" "${main_help}"
assert_not_contains "main help hides deprecated workflow constitution" "cap workflow constitution" "${main_help}"
assert_not_contains "main help hides workflow compile" "cap workflow compile" "${main_help}"
assert_not_contains "main help hides legacy run" "cap run" "${main_help}"
assert_not_contains "main help hides artifact debug" "cap artifact" "${main_help}"
assert_not_contains "main help hides generic promote" "cap promote <src> <dst>" "${main_help}"
assert_not_contains "main help hides make help footer" "make" "${main_help}"

assert_contains "advanced help title" "Advanced / Maintenance" "${advanced_help}"
assert_contains "advanced help shows setup" "cap setup" "${advanced_help}"
assert_contains "advanced help shows sync" "cap sync" "${advanced_help}"
assert_contains "advanced help shows paths" "cap paths" "${advanced_help}"
assert_contains "advanced help shows deprecated workflow constitution" "cap workflow constitution" "${advanced_help}"
assert_contains "advanced help shows artifact debug" "cap artifact" "${advanced_help}"
assert_contains "advanced help shows generic promote" "cap promote <src> <dst>" "${advanced_help}"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
