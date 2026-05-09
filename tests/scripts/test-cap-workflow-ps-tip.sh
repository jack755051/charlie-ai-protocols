#!/usr/bin/env bash
#
# test-cap-workflow-ps-tip.sh — verifies the docker-style follow-up tip
# footer that cap workflow ps emits beneath the table.
#
# Cases:
#   1. ps --all with one run shows table + Tip footer.
#   2. ps --all with empty store shows "No workflow runs found." and
#      omits the Tip footer (no entries to act on).
#   3. ps (active filter) with no active entries omits the Tip footer.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CLI_PY="${REPO_ROOT}/engine/workflow_cli.py"

[ -f "${CLI_PY}" ] || { echo "FAIL: ${CLI_PY} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-ps-tip.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (unexpected): ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# Build a fake status_file with one stable run (avoid the auto-stale
# branch by using a recent updated_at timestamp).
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
STATUS_WITH_RUN="${SANDBOX}/with-run.json"
cat > "${STATUS_WITH_RUN}" <<EOF
{
  "runs": [
    {
      "run_id": "run_test_one",
      "workflow_id": "demo-wf",
      "state": "completed",
      "result": "success",
      "mode": "fast",
      "cli": "claude",
      "created_at": "${NOW}",
      "updated_at": "${NOW}"
    }
  ]
}
EOF

# Empty status store
STATUS_EMPTY="${SANDBOX}/empty.json"
cat > "${STATUS_EMPTY}" <<'EOF'
{ "runs": [] }
EOF

# Case 1: ps all → table + Tip footer
echo "Case 1: ps --all with one run shows Tip footer"
out_1="$("${PYTHON_BIN}" "${CLI_PY}" ps "${STATUS_WITH_RUN}" all 2>&1)"
assert_contains "1a. table header present" "${out_1}" "ALL WORKFLOW RUNS"
assert_contains "1b. run_id row visible" "${out_1}" "run_test_one"
assert_contains "1c. Tip footer present" "${out_1}" "Tip: cap workflow logs"
assert_contains "1d. Tip mentions watch" "${out_1}" "watch <run-id>"
assert_contains "1e. Tip mentions inspect" "${out_1}" "inspect <run-id>"

# Case 2: ps all empty → no Tip
echo "Case 2: ps --all empty store omits Tip"
out_2="$("${PYTHON_BIN}" "${CLI_PY}" ps "${STATUS_EMPTY}" all 2>&1)"
assert_contains "2a. empty message visible" "${out_2}" "No workflow runs found."
assert_not_contains "2b. no Tip footer when empty" "${out_2}" "Tip: cap workflow logs"

# Case 3: ps active filter on empty-of-active store → no Tip
echo "Case 3: ps active filter omits Tip when nothing active"
out_3="$("${PYTHON_BIN}" "${CLI_PY}" ps "${STATUS_WITH_RUN}" active 2>&1)"
# completed run is filtered out by active filter
assert_contains "3a. active-empty message visible" "${out_3}" "No active workflow runs."
assert_not_contains "3b. no Tip footer for active-empty" "${out_3}" "Tip: cap workflow logs"

echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-ps-tip: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
