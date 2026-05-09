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

main_help="$("${CAP_ENTRY}" help)"
advanced_help="$("${CAP_ENTRY}" help --advanced)"

assert_contains "main help title" "Start Here" "${main_help}"
assert_contains "main help shows help flags" "cap help | -h | --help" "${main_help}"
assert_contains "main help advertises advanced" "cap help --advanced" "${main_help}"
assert_contains "main help keeps version" "cap version | -v | --version" "${main_help}"
assert_contains "main help keeps update" "cap update" "${main_help}"
assert_contains "main help keeps skill list" "cap skill list" "${main_help}"
assert_contains "main help keeps workflow list" "cap workflow list" "${main_help}"
assert_contains "main help clarifies repo setup section" "[Repo Setup]" "${main_help}"
assert_contains "main help keeps project init" "cap project init" "${main_help}"
assert_contains "main help clarifies project init purpose" "Connect the current repo to CAP" "${main_help}"
assert_contains "main help keeps project status" "cap project status" "${main_help}"
assert_contains "main help keeps project doctor" "cap project doctor" "${main_help}"
assert_contains "main help clarifies workflow section" "[Run Workflows]" "${main_help}"
assert_contains "main help keeps provider doctor" "cap provider doctor" "${main_help}"
assert_contains "main help keeps workflow run" "cap workflow run <id>" "${main_help}"
assert_contains "main help clarifies workflow run scope" "Run a workflow in a CAP-enabled repo" "${main_help}"
assert_contains "main help keeps workflow dry-run" "cap workflow run --dry-run" "${main_help}"
assert_contains "main help clarifies dry-run" "without calling AI" "${main_help}"
assert_contains "main help shows shortcuts section" "[Shortcuts]" "${main_help}"
assert_contains "main help shows project short alias" "cap p init/status/doctor" "${main_help}"
assert_contains "main help shows project long alias" "cap proj ..." "${main_help}"
assert_contains "main help shows workflow alias" "cap wf ..." "${main_help}"
assert_contains "main help shows provider alias" "cap prov doctor" "${main_help}"

# P3: main help gains an [Observe Runs] block so logs / watch / inspect /
# ps surface on the first screen, and an explicit footer pointing at the
# topic-style help pages.
assert_contains "main help shows observe block"  "[Observe Runs]"             "${main_help}"
assert_contains "main help shows observe ps"     "cap workflow ps"            "${main_help}"
assert_contains "main help shows observe logs"   "cap workflow logs <run-id>" "${main_help}"
assert_contains "main help shows observe watch"  "cap workflow watch <run-id>" "${main_help}"
assert_contains "main help shows observe inspect" "cap workflow inspect <run-id>" "${main_help}"
assert_contains "main help advertises topic help workflow" "cap help workflow" "${main_help}"
assert_contains "main help advertises topic help observe"  "cap help observe"  "${main_help}"

assert_not_contains "main help hides setup" "cap setup" "${main_help}"
assert_not_contains "main help hides sync" "cap sync" "${main_help}"
assert_not_contains "main help hides paths" "cap paths" "${main_help}"
assert_not_contains "main help hides project constitution" "cap project constitution" "${main_help}"
assert_not_contains "main help hides task planned" "cap task plan" "${main_help}"
assert_not_contains "main help hides deprecated workflow constitution" "cap workflow constitution" "${main_help}"
assert_not_contains "main help hides workflow compile" "cap workflow compile" "${main_help}"
assert_not_contains "main help hides workflow show" "cap workflow show" "${main_help}"
assert_not_contains "main help hides workflow plan" "cap workflow plan" "${main_help}"
assert_not_contains "main help hides workflow bind" "cap workflow bind" "${main_help}"
assert_not_contains "main help hides codex wrapper" "cap codex" "${main_help}"
assert_not_contains "main help hides claude wrapper" "cap claude" "${main_help}"
assert_not_contains "main help hides session" "cap session" "${main_help}"
assert_not_contains "main help hides typed promote" "cap promote inspect <id>" "${main_help}"
assert_not_contains "main help hides promote project constitution" "cap promote project-constitution" "${main_help}"
assert_not_contains "main help hides promote workflow" "cap promote workflow" "${main_help}"
assert_not_contains "main help hides replay" "cap replay" "${main_help}"
assert_not_contains "main help hides legacy run" "cap run" "${main_help}"
assert_not_contains "main help hides artifact debug" "cap artifact" "${main_help}"
assert_not_contains "main help hides generic promote" "cap promote <src> <dst>" "${main_help}"
assert_not_contains "main help hides make help footer" "make" "${main_help}"

assert_contains "advanced help title" "Advanced / Maintenance" "${advanced_help}"
assert_contains "advanced help shows setup" "cap setup" "${advanced_help}"
assert_contains "advanced help shows sync" "cap sync" "${advanced_help}"
assert_contains "advanced help shows paths" "cap paths" "${advanced_help}"
assert_contains "advanced help shows project constitution" "cap project constitution" "${advanced_help}"
assert_contains "advanced help shows deprecated workflow constitution" "cap workflow constitution" "${advanced_help}"
assert_contains "advanced help shows workflow show" "cap workflow show" "${advanced_help}"
assert_contains "advanced help shows workflow plan" "cap workflow plan" "${advanced_help}"
assert_contains "advanced help shows workflow bind" "cap workflow bind" "${advanced_help}"
assert_contains "advanced help shows workflow inspect" "cap workflow inspect" "${advanced_help}"
assert_contains "advanced help shows codex wrapper" "cap codex" "${advanced_help}"
assert_contains "advanced help shows claude wrapper" "cap claude" "${advanced_help}"
assert_contains "advanced help shows session inspect" "cap session inspect" "${advanced_help}"
assert_contains "advanced help shows session analyze" "cap session analyze" "${advanced_help}"
assert_contains "advanced help shows typed promote inspect" "cap promote inspect <id>" "${advanced_help}"
assert_contains "advanced help shows promote project constitution" "cap promote project-constitution" "${advanced_help}"
assert_contains "advanced help shows promote workflow" "cap promote workflow" "${advanced_help}"
assert_contains "advanced help shows replay" "cap replay verify" "${advanced_help}"
assert_contains "advanced help shows artifact debug" "cap artifact" "${advanced_help}"
assert_contains "advanced help shows generic promote" "cap promote <src> <dst>" "${advanced_help}"

echo "Summary: $((checks - failures)) passed, ${failures} failed"
[ "${failures}" -eq 0 ]
