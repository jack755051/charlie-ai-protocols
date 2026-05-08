#!/usr/bin/env bash
#
# test-cap-workflow-logs.sh — Phase 1 (Run Log Follow) coverage.
#
# Exercises ``cap workflow logs <run-id>`` and ``-f`` follow mode wired
# in scripts/cap-workflow.sh, with the python-side path resolver in
# engine/workflow_cli.py:cmd_logs. Cases:
#
#   1. existing run + workflow.log → cat of log content matches stdout.
#   2. -f (follow) basic behaviour → after appending a line, follower
#                                    sees both the original and the new
#                                    content within a small timeout.
#   3. missing run                 → exit 1 + "找不到 run_id" stderr.
#   4. missing workflow.log         → exit 1 + "找不到 workflow.log" stderr.
#   5. --cap-home isolation        → resolution honours sandbox cap_home,
#                                    not real ~/.cap.
#
# All cases use ``--cap-home`` so the test never reads the real
# ``~/.cap`` tree. Invokes ``scripts/cap-workflow.sh`` directly so the
# bash dispatcher path (option parsing + cat / tail wiring) is covered,
# not just the python helper.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_WORKFLOW_SH="${REPO_ROOT}/scripts/cap-workflow.sh"

[ -f "${CAP_WORKFLOW_SH}" ] || { echo "FAIL: ${CAP_WORKFLOW_SH} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-logs-test.XXXXXX)"
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
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    needle: ${needle}"
    echo "    head:   $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

# stage_run_dir <case_name> [project_id] [workflow_id]
# Create canonical CAP run_dir layout under the sandbox cap_home and
# echo the run_dir path. Mirrors the layout produced by
# cap-workflow-exec.sh and the test-cap-workflow-inspect.sh fixture.
stage_run_dir() {
  local case_name="$1"
  local project_id="${2:-logs-proj}"
  local workflow_id="${3:-logs-wf}"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/${project_id}/reports/workflows/${workflow_id}/run_${case_name}"
  mkdir -p "${run_dir}"
  printf '%s\n' "${cap_home}|${run_dir}"
}

# ---------------------------------------------------------------------------
# Case 1: existing run + workflow.log → cat output matches log content
# ---------------------------------------------------------------------------
echo "Case 1: existing run prints workflow.log"
IFS='|' read -r CAP_HOME_1 RUN_DIR_1 <<<"$(stage_run_dir case1)"
LOG_CONTENT_1=$'[2026-05-08 12:00:00] step:hello result:ok\n[2026-05-08 12:00:05] step:world result:ok'
printf '%s\n' "${LOG_CONTENT_1}" > "${RUN_DIR_1}/workflow.log"

set +e
out_1="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_1}" run_case1 2>&1)"
rc_1=$?
set -e

assert_eq "1a. exit 0 on hit" "0" "${rc_1}"
assert_contains "1b. log content line 1" "${out_1}" "step:hello result:ok"
assert_contains "1c. log content line 2" "${out_1}" "step:world result:ok"

# ---------------------------------------------------------------------------
# Case 2: -f follow basic behaviour — append after start, follower sees it
# ---------------------------------------------------------------------------
echo "Case 2: -f follow appends are visible"
IFS='|' read -r CAP_HOME_2 RUN_DIR_2 <<<"$(stage_run_dir case2)"
LOG_PATH_2="${RUN_DIR_2}/workflow.log"
printf 'initial-line\n' > "${LOG_PATH_2}"

FOLLOW_OUT="${SANDBOX}/follow.out"
# Run the follower in the background so we can append after it starts.
# 3-second cap so the test cannot hang if tail -f misbehaves; the
# producer appends within ~0.3s and SIGTERM ends the tail cleanly.
(
  bash "${CAP_WORKFLOW_SH}" logs -f --cap-home "${CAP_HOME_2}" run_case2 \
    > "${FOLLOW_OUT}" 2>&1 &
  FOLLOW_PID=$!
  sleep 0.3
  printf 'appended-line\n' >> "${LOG_PATH_2}"
  sleep 0.5
  kill "${FOLLOW_PID}" 2>/dev/null || true
  wait "${FOLLOW_PID}" 2>/dev/null || true
) &
FOLLOW_DRIVER=$!

# Hard timeout safeguard.
(
  sleep 3
  kill "${FOLLOW_DRIVER}" 2>/dev/null || true
) &
TIMEOUT_PID=$!

wait "${FOLLOW_DRIVER}" 2>/dev/null || true
kill "${TIMEOUT_PID}" 2>/dev/null || true
wait "${TIMEOUT_PID}" 2>/dev/null || true

follow_out_content="$(cat "${FOLLOW_OUT}" 2>/dev/null || true)"
assert_contains "2a. follow shows initial line" "${follow_out_content}" "initial-line"
assert_contains "2b. follow shows appended line" "${follow_out_content}" "appended-line"

# ---------------------------------------------------------------------------
# Case 3: missing run → exit 1 + Chinese stderr msg
# ---------------------------------------------------------------------------
echo "Case 3: missing run"
CAP_HOME_3="${SANDBOX}/case3/cap"
mkdir -p "${CAP_HOME_3}/projects"

set +e
out_3="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_3}" run_does_not_exist 2>&1)"
rc_3=$?
set -e

assert_eq "3a. missing run exits 1" "1" "${rc_3}"
assert_contains "3b. missing run stderr names run_id" "${out_3}" "找不到 run_id"
assert_contains "3c. missing run stderr quotes the id" "${out_3}" "run_does_not_exist"

# ---------------------------------------------------------------------------
# Case 4: run dir present but workflow.log missing → exit 1
# ---------------------------------------------------------------------------
echo "Case 4: missing workflow.log"
IFS='|' read -r CAP_HOME_4 RUN_DIR_4 <<<"$(stage_run_dir case4)"
# run_dir exists but no workflow.log inside.

set +e
out_4="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_4}" run_case4 2>&1)"
rc_4=$?
set -e

assert_eq "4a. missing log exits 1" "1" "${rc_4}"
assert_contains "4b. missing log stderr names file" "${out_4}" "找不到 workflow.log"
assert_contains "4c. missing log stderr shows path" "${out_4}" "${RUN_DIR_4}/workflow.log"

# ---------------------------------------------------------------------------
# Case 5: --cap-home isolation — sandbox path beats CAP_HOME env / ~/.cap
# ---------------------------------------------------------------------------
echo "Case 5: --cap-home overrides CAP_HOME env"
IFS='|' read -r CAP_HOME_5A RUN_DIR_5A <<<"$(stage_run_dir case5a)"
printf 'sandbox-A-content\n' > "${RUN_DIR_5A}/workflow.log"

# Different sandbox that should be used because of CAP_HOME env, but
# we expect --cap-home to win and route us to sandbox-A.
DECOY_HOME="${SANDBOX}/decoy/cap"
mkdir -p "${DECOY_HOME}/projects"

set +e
out_5="$(CAP_HOME="${DECOY_HOME}" bash "${CAP_WORKFLOW_SH}" logs \
  --cap-home "${CAP_HOME_5A}" run_case5a 2>&1)"
rc_5=$?
set -e

assert_eq "5a. --cap-home wins exit 0" "0" "${rc_5}"
assert_contains "5b. --cap-home wins routes to sandbox" "${out_5}" "sandbox-A-content"

# ---------------------------------------------------------------------------
# Phase 3 cases — --step resolution with raw.log/md/handoff.md fallback
# ---------------------------------------------------------------------------

# Case 6: --step finds <phase>-<step>.md when only .md exists
echo "Case 6: --step resolves to .md"
IFS='|' read -r CAP_HOME_6 RUN_DIR_6 <<<"$(stage_run_dir case6)"
printf 'md-content-only\n' > "${RUN_DIR_6}/2-spec_step.md"
# workflow.log already staged by stage_run_dir; add nothing else.

set +e
out_6="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_6}" run_case6 \
  --step spec_step 2>&1)"
rc_6=$?
set -e

assert_eq "6a. --step .md exit 0" "0" "${rc_6}"
assert_contains "6b. --step .md content visible" "${out_6}" "md-content-only"

# Case 7: --step prefers raw.log over .md when both exist (legacy run)
echo "Case 7: --step prefers raw.log over .md"
IFS='|' read -r CAP_HOME_7 RUN_DIR_7 <<<"$(stage_run_dir case7)"
printf 'md-newer-content\n' > "${RUN_DIR_7}/3-legacy_step.md"
printf 'rawlog-priority-content\n' > "${RUN_DIR_7}/3-legacy_step.raw.log"

set +e
out_7="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_7}" run_case7 \
  --step legacy_step 2>&1)"
rc_7=$?
set -e

assert_eq "7a. --step raw.log exit 0" "0" "${rc_7}"
assert_contains "7b. raw.log content wins" "${out_7}" "rawlog-priority-content"
# Negative: md content not present (raw.log winner)
if grep -qF "md-newer-content" <<<"${out_7}"; then
  echo "  FAIL: 7c. raw.log should mask md (md content unexpectedly visible)"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: 7c. md content correctly masked by raw.log"
  pass_count=$((pass_count + 1))
fi

# Case 8: --step falls back to handoff.md when neither raw.log nor md exists
echo "Case 8: --step falls back to handoff.md"
IFS='|' read -r CAP_HOME_8 RUN_DIR_8 <<<"$(stage_run_dir case8)"
printf 'handoff-fallback-content\n' > "${RUN_DIR_8}/4-fallback_step.handoff.md"

set +e
out_8="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_8}" run_case8 \
  --step fallback_step 2>&1)"
rc_8=$?
set -e

assert_eq "8a. --step handoff fallback exit 0" "0" "${rc_8}"
assert_contains "8b. handoff content visible as last resort" "${out_8}" "handoff-fallback-content"

# Case 9: --step missing all three suffixes → exit 1 + Chinese stderr
echo "Case 9: --step missing all three"
IFS='|' read -r CAP_HOME_9 RUN_DIR_9 <<<"$(stage_run_dir case9)"
# run_dir mkdir'd; no step files staged so the resolver exhausts the chain.

set +e
out_9="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_9}" run_case9 \
  --step missing_step 2>&1)"
rc_9=$?
set -e

assert_eq "9a. --step missing exits 1" "1" "${rc_9}"
assert_contains "9b. error names step-id (Chinese stderr)" "${out_9}" "找不到 step missing_step"
assert_contains "9c. error mentions fallback chain" "${out_9}" "raw.log / md / handoff.md"

# Case 10: -f --step follows the resolved step file
echo "Case 10: -f --step follows step .md"
IFS='|' read -r CAP_HOME_10 RUN_DIR_10 <<<"$(stage_run_dir case10)"
STEP_LOG_10="${RUN_DIR_10}/5-follow_step.md"
printf 'follow-step-initial\n' > "${STEP_LOG_10}"

FOLLOW_OUT_10="${SANDBOX}/follow-step.out"
(
  bash "${CAP_WORKFLOW_SH}" logs -f --cap-home "${CAP_HOME_10}" run_case10 \
    --step follow_step > "${FOLLOW_OUT_10}" 2>&1 &
  FOLLOW_PID=$!
  sleep 0.3
  printf 'follow-step-appended\n' >> "${STEP_LOG_10}"
  sleep 0.5
  kill "${FOLLOW_PID}" 2>/dev/null || true
  wait "${FOLLOW_PID}" 2>/dev/null || true
) &
FOLLOW_DRIVER_10=$!

(
  sleep 3
  kill "${FOLLOW_DRIVER_10}" 2>/dev/null || true
) &
TIMEOUT_PID_10=$!

wait "${FOLLOW_DRIVER_10}" 2>/dev/null || true
kill "${TIMEOUT_PID_10}" 2>/dev/null || true
wait "${TIMEOUT_PID_10}" 2>/dev/null || true

follow_out_10_content="$(cat "${FOLLOW_OUT_10}" 2>/dev/null || true)"
assert_contains "10a. follow shows initial step content" "${follow_out_10_content}" "follow-step-initial"
assert_contains "10b. follow shows appended step content" "${follow_out_10_content}" "follow-step-appended"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-logs: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
