#!/usr/bin/env bash
#
# test-cap-task-constitution.sh — Smoke for `cap task constitution` alias and
# the matching `cap workflow constitution` deprecation warning (P2 #6).
#
# What this fixture covers (wiring only — no AI / workflow call):
#   Case 1:  cap task --help lists constitution + planned plan/compile/run
#   Case 2:  cap task constitution (no args) → exit 1, own usage message,
#            no deprecation warning (we never reach cap-workflow.sh)
#   Case 3:  cap task plan / compile / run → exit 2 with "(planned)"
#   Case 4:  cap task badcmd → exit 1 with "unknown subcommand"
#   Case 5:  cap workflow constitution (no args) → exit 1 AND emits the
#            "[deprecated] cap workflow constitution ..." warning on stderr
#   Case 6:  CAP_DEPRECATION_SILENT=1 cap workflow constitution (no args)
#            suppresses the warning while keeping the same exit code +
#            usage text
#   Case 7:  cap workflow compile / run-task (no args) DO NOT emit the
#            constitution-specific warning — confirming the deprecation
#            is scoped to the constitution branch only
#   Case 8:  cap-entry.sh task route execs cap-task.sh (smoke help text
#            arrives via the entry layer, not just direct invocation)
#
# What is intentionally OUT OF SCOPE:
#   - Real Task Constitution compilation (engine.task_scoped_compiler
#     calls a model). Behaviour equivalence between `cap task constitution`
#     and `cap workflow constitution` is established by the alias being a
#     thin `exec bash cap-workflow.sh constitution "$@"` plus a pass-through
#     of CAP_DEPRECATION_SILENT — not by re-running the AI path here.
#     A heavier integration test lands in P2 #8.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_TASK="${REPO_ROOT}/scripts/cap-task.sh"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

[ -x "${CAP_TASK}" ]     || { echo "FAIL: ${CAP_TASK} not executable"; exit 1; }
[ -x "${CAP_WORKFLOW}" ] || { echo "FAIL: ${CAP_WORKFLOW} not executable"; exit 1; }
[ -x "${CAP_ENTRY}" ]    || { echo "FAIL: ${CAP_ENTRY} not executable"; exit 1; }

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
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
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (forbidden substring present)"
    echo "    forbidden: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

# Run a command, capture "STDOUT|STDERR|EXIT". The DeprecationWarning lines
# emitted by Python under -W default are filtered out so we test the
# CAP-level deprecation in isolation from interpreter-level deprecation.
run_capture() {
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  "$@" >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"
  err="$(grep -v 'DeprecationWarning' "${tmp_err}" || true)"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: cap task --help lists constitution + planned subcommands"
result="$(run_capture bash "${CAP_TASK}" --help)"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"

assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 lists constitution" "cap task <subcommand>" "${out1}"
assert_contains "case 1 lists constitution body" "constitution <request...>" "${out1}"
assert_contains "case 1 reserved plan" "plan <request...>" "${out1}"
assert_contains "case 1 reserved compile" "compile <request...>" "${out1}"
assert_contains "case 1 reserved run" "run <request...>" "${out1}"
assert_contains "case 1 cross-references boundary memo" "CONSTITUTION-BOUNDARY.md" "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: cap task constitution (no args) → exit 1 + own usage, no deprecation"
result="$(run_capture bash "${CAP_TASK}" constitution)"
err2="${result#*|}"; err2="${err2%|*}"; exit2="${result##*|}"

assert_eq "case 2 exit 1" "1" "${exit2}"
assert_contains "case 2 own usage" "Usage: cap task constitution" "${err2}"
# Crucial: the alias must NOT print the legacy deprecation when it short-
# circuits before exec'ing cap-workflow.sh — the user is on the new path.
assert_not_contains "case 2 no deprecation in alias usage" "[deprecated]" "${err2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: cap task plan / compile / run → exit 2 + (planned)"
for sub in plan compile run; do
  result="$(run_capture bash "${CAP_TASK}" "${sub}" "x")"
  err3="${result#*|}"; err3="${err3%|*}"; exit3="${result##*|}"
  assert_eq "case 3 cap task ${sub} exit 2" "2" "${exit3}"
  assert_contains "case 3 cap task ${sub} (planned) marker" "(planned)" "${err3}"
done

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: cap task badcmd → exit 1 + unknown subcommand"
result="$(run_capture bash "${CAP_TASK}" not-a-real-cmd)"
err4="${result#*|}"; err4="${err4%|*}"; exit4="${result##*|}"

assert_eq "case 4 exit 1" "1" "${exit4}"
assert_contains "case 4 names unknown" "unknown subcommand" "${err4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: cap workflow constitution (no args) → exit 1 + deprecation warning"
result="$(run_capture bash "${CAP_WORKFLOW}" constitution)"
err5="${result#*|}"; err5="${err5%|*}"; exit5="${result##*|}"

assert_eq "case 5 exit 1" "1" "${exit5}"
assert_contains "case 5 deprecation warning present" \
  "[deprecated] cap workflow constitution is deprecated" "${err5}"
assert_contains "case 5 points at new name" "use cap task constitution" "${err5}"
assert_contains "case 5 still prints legacy usage" \
  "Usage: cap workflow constitution" "${err5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: CAP_DEPRECATION_SILENT=1 suppresses the warning"
result="$(run_capture env CAP_DEPRECATION_SILENT=1 bash "${CAP_WORKFLOW}" constitution)"
err6="${result#*|}"; err6="${err6%|*}"; exit6="${result##*|}"

assert_eq "case 6 exit 1 (unchanged)" "1" "${exit6}"
assert_not_contains "case 6 no deprecation when silent" "[deprecated]" "${err6}"
assert_contains "case 6 still prints legacy usage" \
  "Usage: cap workflow constitution" "${err6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: cap workflow compile / run-task untouched by deprecation"
for sub in compile run-task; do
  result="$(run_capture bash "${CAP_WORKFLOW}" "${sub}")"
  err7="${result#*|}"; err7="${err7%|*}"
  assert_not_contains "case 7 ${sub} no deprecation warning" \
    "[deprecated]" "${err7}"
done

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: cap-entry.sh task route execs cap-task.sh"
result="$(run_capture bash "${CAP_ENTRY}" task --help)"
out8="${result%%|*}"; rest="${result#*|}"; exit8="${rest##*|}"

assert_eq "case 8 exit 0" "0" "${exit8}"
# The help text must originate from cap-task.sh, identifiable by the
# planned-subcommand markers — cap-entry.sh's own help text would not
# contain those.
assert_contains "case 8 reaches cap-task help" "constitution <request...>" "${out8}"
assert_contains "case 8 reaches cap-task planned" "(planned)" "${out8}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
