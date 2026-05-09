#!/usr/bin/env bash
#
# test-cap-workflow-watch.sh — Phase 2 (Workflow Watch) coverage.
#
# Exercises ``cap workflow watch <run-id>`` wired in scripts/cap-workflow.sh
# and the python helpers in engine/workflow_cli.py:
#   - cmd_watch
#   - _collect_watch_payload (reuses _try_build_result + _tail_log_lines)
#   - _render_watch_text
#
# Cases:
#   1. --once on finished run → header / step / session / artifact /
#                                last log line all rendered.
#   2. --once on running run  → final_result blank (-) but step/session
#                                still surfaced; non-fatal.
#   3. --json                  → valid JSON, contains last_log_lines key,
#                                workflow_id / run_id consistent with
#                                the fixture.
#   4. missing run             → exit 1 + ``找不到 run_id`` on stderr.
#   5. --cap-home isolation    → flag wins over CAP_HOME env.
#   6. --tail N                → last_log_lines length matches N.
#   7. non-tty fallback        → no --once, stdout piped → exits without
#                                hanging (auto-fallback path).
#
# All cases use ``--cap-home`` so the test never reads the real
# ``~/.cap`` tree.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CAP_WORKFLOW_SH="${REPO_ROOT}/scripts/cap-workflow.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"

[ -f "${CAP_WORKFLOW_SH}" ] || { echo "FAIL: ${CAP_WORKFLOW_SH} missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-watch-test.XXXXXX)"
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

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc} (unexpected match): ${needle}"
    fail_count=$((fail_count + 1))
  fi
}

# stage_run_dir <case_name> [finished:0|1] — create canonical run_dir
# layout. ``finished=1`` adds a ``## Finished`` block to run-summary.md
# so build_workflow_result resolves a final_result; ``finished=0`` leaves
# it open, simulating a still-running snapshot.
stage_run_dir() {
  local case_name="$1"
  local finished="${2:-1}"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/watch-proj/reports/workflows/watch-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {
    "spec_doc": {"artifact": "spec_doc", "source_step": "spec_step", "path": "/tmp/spec.md"}
  },
  "steps": {
    "spec_step": {
      "phase": "1",
      "capability": "specification",
      "execution_state": "validated",
      "blocked_reason": "",
      "output_source": "captured_stdout",
      "output_path": "/tmp/spec.md",
      "handoff_path": ""
    }
  }
}
EOF
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "run_${case_name}",
  "workflow_id": "watch-wf",
  "workflow_name": "Watch Focused Test",
  "sessions": [
    {
      "session_id": "run_${case_name}.1.spec_step",
      "step_id": "spec_step",
      "role": "ba",
      "capability": "specification",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "success",
      "duration_seconds": 12
    }
  ]
}
EOF
  if [ "${finished}" = "1" ]; then
    cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: watch-wf
- workflow_name: Watch Focused Test
- run_id: run_${case_name}
- started_at: 2026-05-05 12:00:00

## Steps

### spec_step

- status: ok
- duration_seconds: 12

## Finished

- finished_at: 2026-05-05 12:00:12
- total_duration_seconds: 12
- completed: 1
- failed: 0
- skipped: 0
EOF
  else
    cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: watch-wf
- workflow_name: Watch Focused Test
- run_id: run_${case_name}
- started_at: 2026-05-05 12:00:00

## Steps

### spec_step

- status: running
EOF
  fi
  printf '[2026-05-05 12:00:00][workflow][started]\n[2026-05-05 12:00:05][step:spec_step][running]\n[2026-05-05 12:00:12][workflow][success]\n' \
    > "${run_dir}/workflow.log"
  printf '%s|%s' "${cap_home}" "${run_dir}"
}

# ---------------------------------------------------------------------------
# Case 1: --once on finished run renders all sections
# ---------------------------------------------------------------------------
echo "Case 1: --once on finished run"
IFS='|' read -r CAP_HOME_1 RUN_DIR_1 <<<"$(stage_run_dir case1 1)"

set +e
out_1="$(bash "${CAP_WORKFLOW_SH}" watch --once --cap-home "${CAP_HOME_1}" run_case1 2>&1)"
rc_1=$?
set -e

assert_eq "1a. --once exits 0" "0" "${rc_1}"
assert_contains "1b. shows watch header" "${out_1}" "# Watch"
assert_contains "1c. shows workflow_id" "${out_1}" "watch-wf"
assert_contains "1d. shows run_id" "${out_1}" "run_case1"
assert_contains "1e. shows step + state" "${out_1}" "spec_step: validated"
assert_contains "1f. shows session lifecycle/result/provider" "${out_1}" "lifecycle=completed result=success provider=claude"
assert_contains "1g. shows artifacts count" "${out_1}" "count: 1"
assert_contains "1h. shows latest artifact" "${out_1}" "latest: spec_doc"
assert_contains "1i. shows last log line" "${out_1}" "[workflow][success]"

# ---------------------------------------------------------------------------
# Case 2: --once on running run still renders, no final_result
# ---------------------------------------------------------------------------
echo "Case 2: --once on running run"
IFS='|' read -r CAP_HOME_2 RUN_DIR_2 <<<"$(stage_run_dir case2 0)"

set +e
out_2="$(bash "${CAP_WORKFLOW_SH}" watch --once --cap-home "${CAP_HOME_2}" run_case2 2>&1)"
rc_2=$?
set -e

assert_eq "2a. --once exits 0 even on running run" "0" "${rc_2}"
assert_contains "2b. shows step" "${out_2}" "spec_step:"
assert_contains "2c. final_result placeholder" "${out_2}" "final_result:  -"

# ---------------------------------------------------------------------------
# Case 3: --json valid JSON + last_log_lines key
# ---------------------------------------------------------------------------
echo "Case 3: --json output"
IFS='|' read -r CAP_HOME_3 RUN_DIR_3 <<<"$(stage_run_dir case3 1)"

set +e
out_3="$(bash "${CAP_WORKFLOW_SH}" watch --json --cap-home "${CAP_HOME_3}" run_case3 2>&1)"
rc_3=$?
set -e

assert_eq "3a. --json exits 0" "0" "${rc_3}"

# Validate JSON parses + extract a few keys.
parse_json="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.stdin.read())
print("workflow_id:", data.get("workflow_id"))
print("run_id:", data.get("run_id"))
print("has_last_log_lines:", "last_log_lines" in data)
print("log_lines_count:", len(data.get("last_log_lines", [])))
print("has_log_tail_window:", "log_tail_window" in data)
' <<<"${out_3}" 2>&1)"
parse_rc=$?
assert_eq "3b. JSON parses cleanly" "0" "${parse_rc}"
assert_contains "3c. workflow_id matches fixture" "${parse_json}" "workflow_id: watch-wf"
assert_contains "3d. run_id matches fixture" "${parse_json}" "run_id: run_case3"
assert_contains "3e. last_log_lines key present" "${parse_json}" "has_last_log_lines: True"
assert_contains "3f. log_tail_window key present" "${parse_json}" "has_log_tail_window: True"

# ---------------------------------------------------------------------------
# Case 4: missing run → exit 1 + Chinese stderr
# ---------------------------------------------------------------------------
echo "Case 4: missing run"
CAP_HOME_4="${SANDBOX}/case4/cap"
mkdir -p "${CAP_HOME_4}/projects"

set +e
out_4="$(bash "${CAP_WORKFLOW_SH}" watch --once --cap-home "${CAP_HOME_4}" run_does_not_exist 2>&1)"
rc_4=$?
set -e

assert_eq "4a. missing run exits 1" "1" "${rc_4}"
assert_contains "4b. missing run names id (Chinese stderr)" "${out_4}" "找不到 run_id"
assert_contains "4c. missing run quotes the id" "${out_4}" "run_does_not_exist"

# ---------------------------------------------------------------------------
# Case 5: --cap-home isolation
# ---------------------------------------------------------------------------
echo "Case 5: --cap-home overrides CAP_HOME env"
IFS='|' read -r CAP_HOME_5 RUN_DIR_5 <<<"$(stage_run_dir case5 1)"

DECOY_HOME="${SANDBOX}/decoy/cap"
mkdir -p "${DECOY_HOME}/projects"

set +e
out_5="$(CAP_HOME="${DECOY_HOME}" bash "${CAP_WORKFLOW_SH}" watch --once \
  --cap-home "${CAP_HOME_5}" run_case5 2>&1)"
rc_5=$?
set -e

assert_eq "5a. --cap-home wins exit 0" "0" "${rc_5}"
assert_contains "5b. routes to sandbox run_id" "${out_5}" "run_case5"

# ---------------------------------------------------------------------------
# Case 6: --tail N controls last_log_lines length
# ---------------------------------------------------------------------------
echo "Case 6: --tail controls log line count"
IFS='|' read -r CAP_HOME_6 RUN_DIR_6 <<<"$(stage_run_dir case6 1)"
# Fixture log has 3 lines; --tail 2 should yield exactly 2.

set +e
out_6="$(bash "${CAP_WORKFLOW_SH}" watch --json --tail 2 \
  --cap-home "${CAP_HOME_6}" run_case6 2>&1)"
rc_6=$?
set -e

assert_eq "6a. --tail exits 0" "0" "${rc_6}"
tail_count="$(${PYTHON_BIN} -c '
import json, sys
print(len(json.loads(sys.stdin.read()).get("last_log_lines", [])))
' <<<"${out_6}")"
assert_eq "6b. last_log_lines == 2" "2" "${tail_count}"

window="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.stdin.read()).get("log_tail_window"))
' <<<"${out_6}")"
assert_eq "6c. log_tail_window reports requested N" "2" "${window}"

# ---------------------------------------------------------------------------
# Case 7: non-tty stdout auto-fallbacks to single-shot
# ---------------------------------------------------------------------------
echo "Case 7: non-tty auto-fallback to once"
IFS='|' read -r CAP_HOME_7 RUN_DIR_7 <<<"$(stage_run_dir case7 1)"
# Without --once, but stdout is captured (not a tty), so the python
# loop should detect not-a-tty and exit after one snapshot. Hard 5s
# safety timeout in case the fallback regresses.
TIMEOUT_OUT="${SANDBOX}/case7/timeout.out"
mkdir -p "$(dirname "${TIMEOUT_OUT}")"

# Bash subshell with PID kill safety net so a hang does not stall CI.
(
  bash "${CAP_WORKFLOW_SH}" watch --cap-home "${CAP_HOME_7}" run_case7 \
    > "${TIMEOUT_OUT}" 2>&1 &
  WATCH_PID=$!
  (
    sleep 5
    kill -9 "${WATCH_PID}" 2>/dev/null || true
  ) &
  KILL_PID=$!
  wait "${WATCH_PID}"
  WATCH_RC=$?
  kill "${KILL_PID}" 2>/dev/null || true
  wait "${KILL_PID}" 2>/dev/null || true
  echo "${WATCH_RC}" > "${SANDBOX}/case7/rc"
)
out_7="$(cat "${TIMEOUT_OUT}" 2>/dev/null || true)"
rc_7="$(cat "${SANDBOX}/case7/rc" 2>/dev/null || echo 124)"

assert_eq "7a. non-tty auto-fallback exits 0" "0" "${rc_7}"
assert_contains "7b. snapshot still rendered" "${out_7}" "run_case7"

# ---------------------------------------------------------------------------
# Phase 4 cases — --compact mode
# ---------------------------------------------------------------------------

# Case 8: --compact renders the terse single-screen view
echo "Case 8: --compact terse view"
IFS='|' read -r CAP_HOME_8 RUN_DIR_8 <<<"$(stage_run_dir case8 1)"

set +e
out_8="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact \
  --cap-home "${CAP_HOME_8}" run_case8 2>&1)"
rc_8=$?
set -e

assert_eq "8a. --compact exits 0" "0" "${rc_8}"
assert_contains "8b. shows compact watch header" "${out_8}" "# Watch (compact)"
assert_contains "8c. one-line summary present" "${out_8}" "watch-wf | run_case8 |"
assert_contains "8d. step rendered as id:state" "${out_8}" "spec_step: validated"
assert_contains "8e. sessions count + last session blurb" "${out_8}" "sessions: 1 (last: completed/success/claude)"
assert_contains "8f. artifacts count line" "${out_8}" "artifacts: 1"
# Compact must NOT emit the verbose # Steps / # Sessions / # Artifacts headers
assert_not_contains "8g. no verbose Steps header" "${out_8}" "# Steps"
assert_not_contains "8h. no verbose Sessions header" "${out_8}" "# Sessions"
assert_not_contains "8i. no verbose Artifacts header" "${out_8}" "# Artifacts"

# Case 9: --compact default --tail collapses to 1
echo "Case 9: --compact default --tail = 1"
IFS='|' read -r CAP_HOME_9 RUN_DIR_9 <<<"$(stage_run_dir case9 1)"
# stage_run_dir writes 3 log lines; verbose mode would show all 3, compact only 1.

set +e
out_9_compact_json="$(bash "${CAP_WORKFLOW_SH}" watch --json --compact \
  --cap-home "${CAP_HOME_9}" run_case9 2>&1)"
rc_9=$?
set -e

assert_eq "9a. --json --compact exits 0" "0" "${rc_9}"
tail_count_compact="$(${PYTHON_BIN} -c '
import json, sys
print(len(json.loads(sys.stdin.read()).get("last_log_lines", [])))
' <<<"${out_9_compact_json}")"
assert_eq "9b. compact default --tail = 1 line" "1" "${tail_count_compact}"

window_compact="$(${PYTHON_BIN} -c '
import json, sys
print(json.loads(sys.stdin.read()).get("log_tail_window"))
' <<<"${out_9_compact_json}")"
assert_eq "9c. log_tail_window reflects compact default" "1" "${window_compact}"

# Case 10: explicit --tail overrides the compact default
echo "Case 10: --compact --tail N overrides default"
IFS='|' read -r CAP_HOME_10 RUN_DIR_10 <<<"$(stage_run_dir case10 1)"

set +e
out_10="$(bash "${CAP_WORKFLOW_SH}" watch --json --compact --tail 3 \
  --cap-home "${CAP_HOME_10}" run_case10 2>&1)"
rc_10=$?
set -e

assert_eq "10a. --tail 3 with --compact exit 0" "0" "${rc_10}"
tail_count_explicit="$(${PYTHON_BIN} -c '
import json, sys
print(len(json.loads(sys.stdin.read()).get("last_log_lines", [])))
' <<<"${out_10}")"
assert_eq "10b. explicit --tail 3 wins over compact default" "3" "${tail_count_explicit}"

# Case 11: --json output ignores --compact (consumers cherry-pick fields)
echo "Case 11: --json with --compact still emits full JSON"
IFS='|' read -r CAP_HOME_11 RUN_DIR_11 <<<"$(stage_run_dir case11 1)"

set +e
out_11="$(bash "${CAP_WORKFLOW_SH}" watch --json --compact \
  --cap-home "${CAP_HOME_11}" run_case11 2>&1)"
rc_11=$?
set -e

assert_eq "11a. --json --compact exits 0" "0" "${rc_11}"
# JSON consumers expect the full structured payload regardless of compact.
keys_present="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.stdin.read())
keys = ["workflow_id", "run_id", "steps", "sessions", "artifacts", "last_log_lines"]
print(",".join(k for k in keys if k in data))
' <<<"${out_11}")"
assert_eq "11b. all top-level keys preserved in --json --compact" \
  "workflow_id,run_id,steps,sessions,artifacts,last_log_lines" "${keys_present}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-watch: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
