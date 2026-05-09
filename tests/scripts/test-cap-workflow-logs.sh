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

# P3: dispatcher-side --help intercept (covers bash flags Python doesn't see)

echo "Case H1: cap workflow logs --help renders dispatcher-side usage"
out_h1="$(bash "${CAP_WORKFLOW_SH}" logs --help 2>&1)"
rc_h1=$?

if [ "${rc_h1}" = "0" ]; then
  echo "  PASS: H1a. logs --help exits 0"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: H1a. logs --help exit ${rc_h1}"
  fail_count=$((fail_count + 1))
fi

assert_contains "H1b. logs --help title" "${out_h1}" "cap workflow logs"
assert_contains "H1c. logs --help shows -f/--follow" "${out_h1}" "-f, --follow"
assert_contains "H1d. logs --help shows --tail (the bash-side flag)" "${out_h1}" "--tail N"
assert_contains "H1e. logs --help shows --step" "${out_h1}" "--step STEP_ID"
assert_contains "H1f. logs --help shows --cap-home" "${out_h1}" "--cap-home PATH"
assert_contains "H1g. logs --help has examples" "${out_h1}" "Examples:"
assert_contains "H1h. logs --help cross-links watch" "${out_h1}" "cap workflow watch"
assert_contains "H1i. logs --help cross-links observe topic" "${out_h1}" "cap help observe"
# Phase 5: --since flag listed in dispatcher --help
assert_contains "H1j. logs --help shows --since" "${out_h1}" "--since VALUE"
assert_contains "H1k. logs --help notes -f incompat" "${out_h1}" "Cannot combine with -f"

# Phase 4 polish: --tail N (docker-style) ----------------------------------

# Case T1: --tail N prints only the last N lines (no follow)
echo "Case T1: --tail N selects trailing window"
IFS='|' read -r CAP_HOME_T1 RUN_DIR_T1 <<<"$(stage_run_dir caseT1)"
LOG_T1="${RUN_DIR_T1}/workflow.log"
printf 'L1\nL2\nL3\nL4\nL5\n' > "${LOG_T1}"

set +e
out_T1="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_T1}" --tail 2 run_caseT1 2>&1)"
rc_T1=$?
set -e

assert_eq "T1a. --tail 2 exits 0" "0" "${rc_T1}"
assert_eq "T1b. --tail 2 prints exactly 2 lines" "2" "$(printf '%s\n' "${out_T1}" | grep -cE '^L[0-9]+$')"
if grep -qF "L4" <<<"${out_T1}" && grep -qF "L5" <<<"${out_T1}"; then
  echo "  PASS: T1c. last 2 lines (L4 L5) present"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: T1c. expected L4+L5 in output"
  fail_count=$((fail_count + 1))
fi
if grep -qF "L1" <<<"${out_T1}"; then
  echo "  FAIL: T1d. earlier lines should be elided"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: T1d. earlier lines correctly elided"
  pass_count=$((pass_count + 1))
fi

# Case T2: --tail with non-positive integer rejected
echo "Case T2: --tail rejects non-positive integers"
IFS='|' read -r CAP_HOME_T2 RUN_DIR_T2 <<<"$(stage_run_dir caseT2)"
printf 'x\n' > "${RUN_DIR_T2}/workflow.log"

set +e
out_T2_zero="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_T2}" --tail 0 run_caseT2 2>&1)"
rc_T2_zero=$?
out_T2_neg="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_T2}" --tail -3 run_caseT2 2>&1)"
rc_T2_neg=$?
out_T2_word="$(bash "${CAP_WORKFLOW_SH}" logs --cap-home "${CAP_HOME_T2}" --tail abc run_caseT2 2>&1)"
rc_T2_word=$?
set -e

assert_eq "T2a. --tail 0 exits 1" "1" "${rc_T2_zero}"
assert_contains "T2b. --tail 0 emits clear error" "${out_T2_zero}" "positive integer"
assert_eq "T2c. --tail -3 exits 1" "1" "${rc_T2_neg}"
assert_eq "T2d. --tail abc exits 1" "1" "${rc_T2_word}"

# Case T3: --tail combined with -f shows last N + follows
echo "Case T3: -f --tail N follows after showing last N"
IFS='|' read -r CAP_HOME_T3 RUN_DIR_T3 <<<"$(stage_run_dir caseT3)"
LOG_T3="${RUN_DIR_T3}/workflow.log"
printf 'A1\nA2\nA3\nA4\n' > "${LOG_T3}"

FOLLOW_OUT_T3="${SANDBOX}/follow-tail.out"
(
  bash "${CAP_WORKFLOW_SH}" logs -f --tail 2 --cap-home "${CAP_HOME_T3}" run_caseT3 \
    > "${FOLLOW_OUT_T3}" 2>&1 &
  FOLLOW_PID=$!
  sleep 0.3
  printf 'A5\n' >> "${LOG_T3}"
  sleep 0.5
  kill "${FOLLOW_PID}" 2>/dev/null || true
  wait "${FOLLOW_PID}" 2>/dev/null || true
) &
FOLLOW_DRIVER_T3=$!
(
  sleep 3
  kill "${FOLLOW_DRIVER_T3}" 2>/dev/null || true
) &
TIMEOUT_PID_T3=$!
wait "${FOLLOW_DRIVER_T3}" 2>/dev/null || true
kill "${TIMEOUT_PID_T3}" 2>/dev/null || true
wait "${TIMEOUT_PID_T3}" 2>/dev/null || true

follow_out_T3_content="$(cat "${FOLLOW_OUT_T3}" 2>/dev/null || true)"
# A1/A2 should be elided (--tail 2), A3/A4 are the trailing window, A5 is the live append.
if grep -qF "A1" <<<"${follow_out_T3_content}"; then
  echo "  FAIL: T3a. earlier lines should be elided by --tail 2"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: T3a. earlier lines elided by --tail"
  pass_count=$((pass_count + 1))
fi
assert_contains "T3b. trailing window line A3 visible" "${follow_out_T3_content}" "A3"
assert_contains "T3c. trailing window line A4 visible" "${follow_out_T3_content}" "A4"
assert_contains "T3d. follow picks up appended A5" "${follow_out_T3_content}" "A5"

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
# Phase 5: --since timestamp filter
# ---------------------------------------------------------------------------

# Shared fixture for --since cases — workflow.log spans 5 timestamped lines.
echo "Case S1: --since absolute cutoff selects trailing lines"
IFS='|' read -r CAP_HOME_S1 RUN_DIR_S1 <<<"$(stage_run_dir caseS1)"
LOG_S1="${RUN_DIR_S1}/workflow.log"
cat > "${LOG_S1}" <<'EOF'
[2026-05-09 09:59:50][workflow][started]
[2026-05-09 10:00:00][step:s1][ok]
[2026-05-09 10:00:03][step:s2][failed]
[2026-05-09 10:00:05][workflow][failed]
not-a-timestamped-line-should-be-skipped
EOF

set +e
out_S1="$(bash "${CAP_WORKFLOW_SH}" logs --since "2026-05-09 10:00:02" \
  --cap-home "${CAP_HOME_S1}" run_caseS1 2>&1)"
rc_S1=$?
set -e

assert_eq "S1a. --since exit 0" "0" "${rc_S1}"
# Lines >= cutoff: s2 failed (10:00:03), workflow failed (10:00:05).
assert_contains "S1b. cutoff line s2 failed visible" "${out_S1}" "step:s2"
assert_contains "S1c. cutoff line workflow failed visible" "${out_S1}" "[workflow][failed]"
# Earlier lines must be elided.
if grep -qF "step:s1" <<<"${out_S1}"; then
  echo "  FAIL: S1d. earlier line step:s1 should be elided"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: S1d. earlier line step:s1 elided"
  pass_count=$((pass_count + 1))
fi
if grep -qF "started" <<<"${out_S1}"; then
  echo "  FAIL: S1e. earlier line workflow started should be elided"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: S1e. earlier line workflow started elided"
  pass_count=$((pass_count + 1))
fi
# Lines without a parseable timestamp must be skipped (docker-style).
if grep -qF "not-a-timestamped-line" <<<"${out_S1}"; then
  echo "  FAIL: S1f. untimestamped line should be skipped"
  fail_count=$((fail_count + 1))
else
  echo "  PASS: S1f. untimestamped line skipped"
  pass_count=$((pass_count + 1))
fi

# Case S2: --since 1d on a fresh fixture keeps everything (cutoff far in the past)
echo "Case S2: --since relative duration"
IFS='|' read -r CAP_HOME_S2 RUN_DIR_S2 <<<"$(stage_run_dir caseS2)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
printf '[%s][step:s1][ok]\n[%s][workflow][success]\n' "${NOW}" "${NOW}" \
  > "${RUN_DIR_S2}/workflow.log"

set +e
out_S2="$(bash "${CAP_WORKFLOW_SH}" logs --since 1d \
  --cap-home "${CAP_HOME_S2}" run_caseS2 2>&1)"
rc_S2=$?
set -e

assert_eq "S2a. --since 1d exit 0" "0" "${rc_S2}"
assert_contains "S2b. recent line within 1d window visible" "${out_S2}" "step:s1"
assert_contains "S2c. workflow success line visible" "${out_S2}" "workflow][success]"

# Case S3: --since invalid value exits 1 with parse error
echo "Case S3: --since rejects garbage"
IFS='|' read -r CAP_HOME_S3 RUN_DIR_S3 <<<"$(stage_run_dir caseS3)"
printf '[2026-05-09 10:00:00][workflow][started]\n' > "${RUN_DIR_S3}/workflow.log"

set +e
out_S3="$(bash "${CAP_WORKFLOW_SH}" logs --since "not-a-time" \
  --cap-home "${CAP_HOME_S3}" run_caseS3 2>&1)"
rc_S3=$?
set -e

assert_eq "S3a. --since invalid exit 1" "1" "${rc_S3}"
assert_contains "S3b. parse error names the value" "${out_S3}" "not-a-time"
assert_contains "S3c. parse error names accepted formats" "${out_S3}" "30s/5m/1h/2d"

# Case S4: --since combined with -f rejected up front
echo "Case S4: --since + -f rejected"
IFS='|' read -r CAP_HOME_S4 RUN_DIR_S4 <<<"$(stage_run_dir caseS4)"
printf '[2026-05-09 10:00:00][workflow][started]\n' > "${RUN_DIR_S4}/workflow.log"

set +e
out_S4="$(bash "${CAP_WORKFLOW_SH}" logs --since 30s -f \
  --cap-home "${CAP_HOME_S4}" run_caseS4 2>&1)"
rc_S4=$?
set -e

assert_eq "S4a. --since + -f exit 1" "1" "${rc_S4}"
assert_contains "S4b. error explains incompat" "${out_S4}" "cannot be combined with -f"
assert_contains "S4c. error suggests workaround" "${out_S4}" "single-shot"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-logs: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
