#!/usr/bin/env bash
#
# test-step-failure-detail.sh — gate for the workflow-exec failure
# detail extractor (cap-workflow-exec.sh:extract_step_failure_detail).
#
# Goal: ensure the new helper that surfaces a step's `reason:` /
# `detail:` lines from its artifact produces the compact one-line
# summary that gets wired into workflow.log entries and the
# agent-sessions ledger failure_reason field. With this in place
# `cap session inspect` / `cap session analyze` show the actual
# failure category (e.g. PARSE_ERROR vs MISSING_REQUIRED) instead
# of a bare "failed" / "schema_validation_failed" string.
#
# Coverage (helper extracted via sed; no real workflow execution):
#   Case 1 reason + multi-detail:   artifact with reason: + 2 detail:
#                                   lines → reason=...;detail=A|B
#   Case 2 reason only:             artifact with reason: + no detail:
#                                   → reason=...
#   Case 3 detail only:             artifact with detail: + no reason:
#                                   → detail=...
#   Case 4 no markers:              artifact with neither → empty output
#   Case 5 missing artifact:        non-existent path → empty output
#                                   (no error, no FileNotFoundError)
#   Case 6 historical fixture:      run against a known prior failure
#                                   shape (PARSE_ERROR + rc) → matches
#                                   the v0.21.x persist-task-constitution
#                                   fail_with output exactly.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/scripts/cap-workflow-exec.sh" ] || {
  echo "FAIL: scripts/cap-workflow-exec.sh missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-failure-detail-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

# Extract the helper into a sourceable file so we don't run the full
# cap-workflow-exec.sh boilerplate.
HELPER_SRC="${SANDBOX}/helper.sh"
sed -n '/^extract_step_failure_detail()/,/^}$/p' "${REPO_ROOT}/scripts/cap-workflow-exec.sh" > "${HELPER_SRC}"
[ -s "${HELPER_SRC}" ] || { echo "FAIL: could not extract extract_step_failure_detail"; exit 1; }

run_helper() {
  bash -c "source '${HELPER_SRC}'; extract_step_failure_detail '$1'"
}

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

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: reason + multi-detail extraction"
A1="${SANDBOX}/c1.md"
cat > "${A1}" <<'EOF'
# step output

condition: workflow_step_failed
reason: validation_failed
detail: MISSING_REQUIRED:goal,success_criteria
detail: rc=3
EOF
out1="$(run_helper "${A1}")"
assert_eq "compact summary"  "reason=validation_failed;detail=MISSING_REQUIRED:goal,success_criteria|rc=3"  "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: reason only (no detail lines)"
A2="${SANDBOX}/c2.md"
cat > "${A2}" <<'EOF'
condition: workflow_step_failed
reason: missing_input_artifact
EOF
out2="$(run_helper "${A2}")"
assert_eq "reason-only summary" "reason=missing_input_artifact" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: detail only (no reason line)"
A3="${SANDBOX}/c3.md"
cat > "${A3}" <<'EOF'
detail: some raw error string
EOF
out3="$(run_helper "${A3}")"
assert_eq "detail-only summary" "detail=some raw error string" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: no markers → empty output"
A4="${SANDBOX}/c4.md"
cat > "${A4}" <<'EOF'
# Just a step output with no fail_with markers
some plain text
another line
EOF
out4="$(run_helper "${A4}")"
assert_eq "no markers → empty"  ""  "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: missing artifact → empty output, no error"
out5="$(run_helper "${SANDBOX}/nope-not-a-file.md")"
assert_eq "missing file → empty" "" "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: historical PARSE_ERROR shape from persist-task-constitution"
A6="${SANDBOX}/c6.md"
cat > "${A6}" <<'EOF'
# persist_task_constitution

## Task Constitution Persistence Report

condition: workflow_step_failed
reason: validation_failed
detail: PARSE_ERROR:Extra data: line 334 column 1 (char 12886)
detail: rc=2
EOF
out6="$(run_helper "${A6}")"
assert_eq "historical persist failure preserved verbatim" \
  "reason=validation_failed;detail=PARSE_ERROR:Extra data: line 334 column 1 (char 12886)|rc=2" \
  "${out6}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "step-failure-detail: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
