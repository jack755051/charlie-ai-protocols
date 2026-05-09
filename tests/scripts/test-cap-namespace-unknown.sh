#!/usr/bin/env bash
#
# test-cap-namespace-unknown.sh — verifies that every namespace
# dispatcher (skill / provider / project / task / replay / workflow)
# emits a consistent "Unknown <ns> subcommand: <x>" + "Available: ..."
# error format. The previous v0.24.x convention drifted across files
# (some used `cap-task: unknown subcommand:` lowercase + no Available
# line). This fixture pins the unified shape.
#
# Note on workflow: `cap workflow` keeps the shorthand fallback
# (`cap workflow <id>` -> show <id>), so an unknown subcommand goes
# through resolve_workflow_ref and surfaces as "workflow not found"
# plus an explicit Available subcommands hint. We assert both bits
# so future shorthand changes don't silently drop the hint.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

failures=0
checks=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  checks=$((checks + 1))
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    failures=$((failures + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  checks=$((checks + 1))
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc} — expected '${expected}' got '${actual}'"
    failures=$((failures + 1))
  fi
}

run_ns() {
  local script="$1"
  shift
  local out rc=0
  out="$(bash "${REPO_ROOT}/scripts/${script}" "$@" 2>&1)" || rc=$?
  printf '%s\t%s' "${rc}" "${out}"
}

# ── skill (already aligned in v0.24.2) ───────────────────────────────
echo "Namespace: skill"
result="$(run_ns cap-entry.sh skill garbage)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "skill exits 1" "1" "${rc}"
assert_contains "skill uses unified header" "${out}" "Unknown skill subcommand: garbage"
assert_contains "skill lists Available" "${out}" "Available: cap skill list | registry | check-aliases"

# ── provider (already aligned in v0.24.2) ────────────────────────────
echo "Namespace: provider"
result="$(run_ns cap-entry.sh provider garbage)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "provider exits 1" "1" "${rc}"
assert_contains "provider uses unified header" "${out}" "Unknown provider subcommand: garbage"
assert_contains "provider lists Available" "${out}" "Available: cap provider doctor"

# ── task (newly aligned in v0.24.4) ──────────────────────────────────
echo "Namespace: task"
result="$(run_ns cap-task.sh garbage)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "task exits 1" "1" "${rc}"
assert_contains "task uses unified header" "${out}" "Unknown task subcommand: garbage"
assert_contains "task lists Available" "${out}" "Available: cap task constitution | plan | compile | run"
# Pin the regression: the old "cap-task: unknown subcommand:" wording must not return.
if grep -qF "cap-task: unknown subcommand" <<<"${out}"; then
  echo "  FAIL: legacy cap-task wording leaked back"
  failures=$((failures + 1))
else
  echo "  PASS: legacy cap-task wording absent"
fi
checks=$((checks + 1))

# ── replay (newly aligned in v0.24.4) ────────────────────────────────
echo "Namespace: replay"
result="$(run_ns cap-replay.sh garbage)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "replay exits 1" "1" "${rc}"
assert_contains "replay uses unified header" "${out}" "Unknown replay subcommand: garbage"
assert_contains "replay lists Available" "${out}" "Available: cap replay verify"
if grep -qF "cap replay: unknown subcommand" <<<"${out}"; then
  echo "  FAIL: legacy cap replay wording leaked back"
  failures=$((failures + 1))
else
  echo "  PASS: legacy cap replay wording absent"
fi
checks=$((checks + 1))

# ── project (newly aligned in v0.24.4) ───────────────────────────────
echo "Namespace: project"
result="$(run_ns cap-project.sh garbage)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "project exits 1" "1" "${rc}"
assert_contains "project uses unified header" "${out}" "Unknown project subcommand: garbage"
assert_contains "project lists Available" "${out}" "Available: cap project init | status | doctor | constitution | migrate-config"
if grep -qF "cap-project: unknown subcommand" <<<"${out}"; then
  echo "  FAIL: legacy cap-project wording leaked back"
  failures=$((failures + 1))
else
  echo "  PASS: legacy cap-project wording absent"
fi
checks=$((checks + 1))

# ── workflow (shorthand-aware: keeps "workflow not found:" line, adds Available hint) ─
echo "Namespace: workflow (shorthand-aware)"
result="$(run_ns cap-workflow.sh garbage-typo)"
rc="${result%%$'\t'*}"
out="${result#*$'\t'}"
assert_eq "workflow exits 1" "1" "${rc}"
assert_contains "workflow keeps not-found line" "${out}" "workflow not found: garbage-typo"
assert_contains "workflow adds disambiguation hint" "${out}" "neither a registered workflow id nor a known subcommand"
assert_contains "workflow lists Available subcommands" "${out}" "Available subcommands: list | ps | show | inspect | logs | watch | run"
assert_contains "workflow points to list discovery" "${out}" "Run 'cap workflow list'"

echo ""
total=$((checks - failures))
echo "cap-namespace-unknown: ${total} passed, ${failures} failed (of ${checks})"
[ "${failures}" -eq 0 ]
