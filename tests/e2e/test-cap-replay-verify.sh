#!/usr/bin/env bash
#
# test-cap-replay-verify.sh — H1 #4 e2e for `cap replay verify <run_id>`.
#
# Builds an isolated sandbox project + CAP_HOME, plants a fake run
# directory with a known agent_skills_baseline, then invokes the shell
# wrapper to exercise:
#   1. run_id resolution via workflow_report_dir glob
#   2. happy-path replayable verdict (exit 0)
#   3. drifted_incompatible verdict (exit 4) when sandbox agent-skills
#      change between run-time baseline and verification time
#   4. not_found verdict + exit 2 for an unknown run_id
#   5. --no-write flag prints verdict but skips disk persistence
#   6. --json flag emits raw envelope
#   7. absolute-path argument bypasses run_id glob
#   8. snapshots/agent-skills.json mirror carries full baseline
#
# Sandbox isolation: CAP_HOME / CAP_AGENT_SKILLS_DIR / CAP_ROOT all
# point under SANDBOX so the test never touches the real cap-protocols
# repo or the user's ~/.cap.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CAP_REPLAY_SH="${REPO_ROOT}/scripts/cap-replay.sh"
SNAPSHOT_PY="${REPO_ROOT}/engine/agent_skills_snapshot.py"

[ -f "${CAP_REPLAY_SH}" ] || { echo "FAIL: scripts/cap-replay.sh missing"; exit 1; }
[ -f "${SNAPSHOT_PY}"   ] || { echo "FAIL: engine/agent_skills_snapshot.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-replay-e2e.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "${haystack}" in
    *"${needle}"*)
      echo "  PASS: ${desc}"
      pass_count=$((pass_count + 1)) ;;
    *)
      echo "  FAIL: ${desc}"
      echo "    expected substring: ${needle}"
      fail_count=$((fail_count + 1)) ;;
  esac
}

# ── Sandbox layout ──────────────────────────────────────────────────

PROJECT_ROOT="${SANDBOX}/proj"
CAP_HOME_DIR="${SANDBOX}/cap_home"
AGENT_SKILLS_DIR="${SANDBOX}/agent-skills"
CAP_ROOT_DIR="${SANDBOX}/cap_root"

mkdir -p "${PROJECT_ROOT}" "${CAP_HOME_DIR}" "${AGENT_SKILLS_DIR}" "${CAP_ROOT_DIR}"

cat > "${PROJECT_ROOT}/.cap.project.yaml" <<'EOF'
project_id: replay-test
EOF

cat > "${AGENT_SKILLS_DIR}/01-supervisor-agent.md" <<'EOF'
# Supervisor sandbox prompt
EOF
cat > "${AGENT_SKILLS_DIR}/04-frontend-agent.md" <<'EOF'
# Frontend sandbox prompt
EOF
cat > "${AGENT_SKILLS_DIR}/07-qa-agent.md" <<'EOF'
# QA sandbox prompt
EOF

# Compute the canonical baseline that the original run will record.
SNAPSHOT_BASELINE="$(CAP_AGENT_SKILLS_DIR="${AGENT_SKILLS_DIR}" CAP_ROOT="${CAP_ROOT_DIR}" \
  "${PYTHON_BIN}" "${SNAPSHOT_PY}" snapshot)"

# Build a fake run dir under workflow_report_dir.
RUN_ID="run_20260507000000_replaytest"
WORKFLOW_ID="test-workflow"
WORKFLOW_REPORT_DIR="${CAP_HOME_DIR}/projects/replay-test/reports/workflows"
RUN_DIR="${WORKFLOW_REPORT_DIR}/${WORKFLOW_ID}/${RUN_ID}"
mkdir -p "${RUN_DIR}"
# Build the agent-sessions ledger: includes the baseline + sessions
# referencing prompt files we will later (in case 3) modify.
SESSIONS_JSON='[{"session_id":"s1","prompt_file":"agent-skills/04-frontend-agent.md"},{"session_id":"s2","prompt_file":"agent-skills/07-qa-agent.md"}]'
cat > "${RUN_DIR}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "${RUN_ID}",
  "workflow_id": "${WORKFLOW_ID}",
  "workflow_name": "test",
  "agent_skills_baseline": ${SNAPSHOT_BASELINE},
  "sessions": ${SESSIONS_JSON}
}
EOF

# Helper: invoke cap-replay.sh with the right env. cd-into-project-root
# is required because cap-paths.sh walks up from cwd to find project.
run_replay() {
  local args=("$@")
  CAP_HOME="${CAP_HOME_DIR}" \
    CAP_AGENT_SKILLS_DIR="${AGENT_SKILLS_DIR}" \
    CAP_ROOT="${CAP_ROOT_DIR}" \
    bash -c "cd '${PROJECT_ROOT}' && bash '${CAP_REPLAY_SH}' \"\$@\"" -- "${args[@]}"
}

# ── Case 1: replayable (exit 0) via run_id glob resolution ───────────

echo "Case 1: cap replay verify <run_id> resolves and returns replayable"
set +e
OUT1="$(run_replay verify "${RUN_ID}" 2>&1)"
RC1=$?
set -e
assert_eq "case1: exit code 0 (replayable)" "0" "${RC1}"
assert_contains "case1: stdout contains replayable verdict" "cap replay: replayable" "${OUT1}"
assert_contains "case1: shows verdict file path" "${RUN_DIR}/replay-verdict.json" "${OUT1}"
[ -f "${RUN_DIR}/replay-verdict.json" ] && {
  echo "  PASS: case1: replay-verdict.json written"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case1: replay-verdict.json missing"
  fail_count=$((fail_count + 1))
}
[ -f "${RUN_DIR}/snapshots/agent-skills.json" ] && {
  echo "  PASS: case1: snapshots/agent-skills.json mirror written"
  pass_count=$((pass_count + 1))
} || {
  echo "  FAIL: case1: snapshot mirror missing"
  fail_count=$((fail_count + 1))
}

# ── Case 2: snapshot mirror carries full baseline (with prompt_files) ─

echo ""
echo "Case 2: snapshot mirror is the full baseline (not just the summary)"
HAS_PROMPT_FILES="$("${PYTHON_BIN}" -c "
import json
print('prompt_files' in json.load(open('${RUN_DIR}/snapshots/agent-skills.json')))")"
assert_eq "case2: mirror contains prompt_files" "True" "${HAS_PROMPT_FILES}"

# ── Case 3: drifted_incompatible (exit 4) after editing a used prompt ─

echo ""
echo "Case 3: edit 04-frontend-agent.md → drifted_incompatible (exit 4)"
echo "# Frontend sandbox prompt EDITED" > "${AGENT_SKILLS_DIR}/04-frontend-agent.md"
set +e
OUT3="$(run_replay verify "${RUN_ID}" 2>&1)"
RC3=$?
set -e
assert_eq "case3: exit code 4 (drifted_incompatible)" "4" "${RC3}"
assert_contains "case3: stdout marks drifted_incompatible" \
  "cap replay: drifted_incompatible" "${OUT3}"
assert_contains "case3: reason names 04-frontend-agent.md" \
  "04-frontend-agent.md" "${OUT3}"

# ── Case 4: not_found (exit 2) ──────────────────────────────────────

echo ""
echo "Case 4: unknown run_id → not_found (exit 2)"
set +e
OUT4="$(run_replay verify "run_does_not_exist_at_all" 2>&1)"
RC4=$?
set -e
assert_eq "case4: exit code 2 (not_found)" "2" "${RC4}"
assert_contains "case4: stderr names the missing run_id" \
  "run_does_not_exist_at_all" "${OUT4}"

# ── Case 5: --json flag prints raw envelope ─────────────────────────

echo ""
echo "Case 5: --json flag returns raw verdict JSON to stdout"
# Restore frontend file content so verdict goes back to replayable.
cat > "${AGENT_SKILLS_DIR}/04-frontend-agent.md" <<'EOF'
# Frontend sandbox prompt
EOF
set +e
OUT5="$(run_replay verify "${RUN_ID}" --json 2>&1)"
RC5=$?
set -e
assert_eq "case5: --json exit code 0" "0" "${RC5}"
JSON_VERDICT="$(printf '%s' "${OUT5}" | "${PYTHON_BIN}" -c "
import json, sys
try:
    print(json.loads(sys.stdin.read())['verdict'])
except Exception:
    print('parse-failed')
")"
assert_eq "case5: --json output is parsable JSON with verdict" \
  "replayable" "${JSON_VERDICT}"

# ── Case 6: absolute path bypasses run_id glob ─────────────────────

echo ""
echo "Case 6: absolute run_dir argument resolves directly (no glob needed)"
set +e
OUT6="$(run_replay verify "${RUN_DIR}" 2>&1)"
RC6=$?
set -e
assert_eq "case6: absolute path exit code 0" "0" "${RC6}"
assert_contains "case6: shows run_dir in summary" "${RUN_DIR}" "${OUT6}"

# ── Case 7: --no-write flag skips disk persistence ──────────────────

echo ""
echo "Case 7: --no-write flag skips materialising files for a fresh run"
NEW_RUN_ID="run_20260507111111_nowrite"
NEW_RUN_DIR="${WORKFLOW_REPORT_DIR}/${WORKFLOW_ID}/${NEW_RUN_ID}"
mkdir -p "${NEW_RUN_DIR}"
cat > "${NEW_RUN_DIR}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "${NEW_RUN_ID}",
  "workflow_id": "${WORKFLOW_ID}",
  "workflow_name": "test",
  "agent_skills_baseline": ${SNAPSHOT_BASELINE},
  "sessions": ${SESSIONS_JSON}
}
EOF

set +e
OUT7="$(run_replay verify "${NEW_RUN_ID}" --no-write 2>&1)"
RC7=$?
set -e
assert_eq "case7: --no-write exit code 0" "0" "${RC7}"
[ -f "${NEW_RUN_DIR}/replay-verdict.json" ] && {
  echo "  FAIL: case7: replay-verdict.json should NOT be written with --no-write"
  fail_count=$((fail_count + 1))
} || {
  echo "  PASS: case7: replay-verdict.json absent (--no-write honoured)"
  pass_count=$((pass_count + 1))
}
[ -d "${NEW_RUN_DIR}/snapshots" ] && {
  echo "  FAIL: case7: snapshots/ should NOT be created with --no-write"
  fail_count=$((fail_count + 1))
} || {
  echo "  PASS: case7: snapshots/ absent (--no-write honoured)"
  pass_count=$((pass_count + 1))
}

# ── Case 8: --project-id flag for bootstrap / cross-project runs ────

echo ""
echo "Case 8: --project-id <id> globs under a different project's reports"
ALT_PROJECT_ID="alt-project-bootstrap"
ALT_RUN_DIR="${CAP_HOME_DIR}/projects/${ALT_PROJECT_ID}/reports/workflows/${WORKFLOW_ID}/run_alt_xxx"
mkdir -p "${ALT_RUN_DIR}"
cat > "${ALT_RUN_DIR}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "run_alt_xxx",
  "workflow_id": "${WORKFLOW_ID}",
  "workflow_name": "alt",
  "agent_skills_baseline": ${SNAPSHOT_BASELINE},
  "sessions": ${SESSIONS_JSON}
}
EOF

# Without --project-id: cwd resolves to "replay-test", run_alt_xxx not found there.
set +e
OUT8A="$(run_replay verify run_alt_xxx 2>&1)"
RC8A=$?
set -e
assert_eq "case8a: without --project-id → not_found exit 2" "2" "${RC8A}"
assert_contains "case8a: error names default project's report dir" \
  "replay-test" "${OUT8A}"

# With --project-id: glob under the alt project's report dir → resolved.
set +e
OUT8B="$(run_replay verify run_alt_xxx --project-id "${ALT_PROJECT_ID}" 2>&1)"
RC8B=$?
set -e
assert_eq "case8b: --project-id resolves bootstrap-project run → exit 0" \
  "0" "${RC8B}"
assert_contains "case8b: stdout shows replayable verdict" \
  "cap replay: replayable" "${OUT8B}"

# --project-id with absolute path → flag is ignored (path is unambiguous).
set +e
OUT8C="$(run_replay verify "${ALT_RUN_DIR}" --project-id wrong-id 2>&1)"
RC8C=$?
set -e
assert_eq "case8c: absolute path overrides --project-id (still resolves)" \
  "0" "${RC8C}"

# --project-id missing value → usage error.
set +e
OUT8D="$(run_replay verify run_xxx --project-id 2>&1)"
RC8D=$?
set -e
case "${RC8D}" in
  1)
    echo "  PASS: case8d: --project-id without value exits 1"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: case8d: expected exit 1, got ${RC8D}"
    fail_count=$((fail_count + 1)) ;;
esac

echo ""
echo "Summary: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
