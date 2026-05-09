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
# P2: step renders with status glyph + normalized label.
assert_contains "1e. shows step glyph + state" "${out_1}" "✓ spec_step: ok"
assert_contains "1f. shows session lifecycle/result/provider" "${out_1}" "lifecycle=completed result=success provider=claude"
assert_contains "1g. shows artifacts count" "${out_1}" "count: 1"
# P2: rename "latest:" -> "latest_artifact:" for clarity vs run/log timestamps.
assert_contains "1h. shows latest_artifact" "${out_1}" "latest_artifact: spec_doc"
assert_contains "1i. shows last log line" "${out_1}" "[workflow][success]"
# P2: completed run shows # Next section pointing at inspect.
assert_contains "1j. verbose # Next section present" "${out_1}" "# Next"
assert_contains "1k. Next on completed run suggests inspect" "${out_1}" "cap workflow inspect run_case1"

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
# P2: compact step row carries status glyph + normalized state label.
assert_contains "8d. step row has glyph + state" "${out_8}" "✓ spec_step: ok"
assert_contains "8e. sessions count + last session blurb" "${out_8}" "sessions: 1 (last: completed/success/claude)"
# P2: compact artifacts line includes latest artifact name (path stays in verbose).
assert_contains "8f. compact artifacts shows latest name" "${out_8}" "artifacts: 1 (latest: spec_doc)"
# Compact must NOT emit the verbose # Steps / # Sessions / # Artifacts headers
assert_not_contains "8g. no verbose Steps header" "${out_8}" "# Steps"
assert_not_contains "8h. no verbose Sessions header" "${out_8}" "# Sessions"
assert_not_contains "8i. no verbose Artifacts header" "${out_8}" "# Artifacts"
# P2: compact dashboard shows Next: footer; completed run -> inspect.
assert_contains "8j. compact Next footer present" "${out_8}" "Next:"
assert_contains "8k. completed compact suggests inspect" "${out_8}" "cap workflow inspect run_case8"
# P2: completed run header glyph reflects state.
assert_contains "8l. compact header has ok glyph" "${out_8}" "✓ ok"

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
# P3: dispatcher-side --help intercept
# ---------------------------------------------------------------------------

echo "Case H1: cap workflow watch --help renders dispatcher-side usage"
out_w_h1="$(bash "${CAP_WORKFLOW_SH}" watch --help 2>&1)"
rc_w_h1=$?

if [ "${rc_w_h1}" = "0" ]; then
  echo "  PASS: H1a. watch --help exits 0"
  pass_count=$((pass_count + 1))
else
  echo "  FAIL: H1a. watch --help exit ${rc_w_h1}"
  fail_count=$((fail_count + 1))
fi

assert_contains "H1b. watch --help title" "${out_w_h1}" "cap workflow watch"
assert_contains "H1c. watch --help shows --once" "${out_w_h1}" "--once"
assert_contains "H1d. watch --help shows --json" "${out_w_h1}" "--json"
assert_contains "H1e. watch --help shows --compact" "${out_w_h1}" "--compact"
assert_contains "H1f. watch --help shows --interval" "${out_w_h1}" "--interval SEC"
assert_contains "H1g. watch --help shows --tail" "${out_w_h1}" "--tail N"
assert_contains "H1h. watch --help shows --cap-home" "${out_w_h1}" "--cap-home PATH"
assert_contains "H1i. watch --help has Behaviour matrix" "${out_w_h1}" "Behaviour:"
assert_contains "H1j. watch --help notes status glyphs" "${out_w_h1}" "status glyphs"
assert_contains "H1k. watch --help has examples" "${out_w_h1}" "Examples:"
assert_contains "H1l. watch --help cross-links logs" "${out_w_h1}" "cap workflow logs"
assert_contains "H1m. watch --help cross-links observe topic" "${out_w_h1}" "cap help observe"
# Phase 5 filter flags surfaced in dispatcher --help.
assert_contains "H1n. watch --help shows --failed-only" "${out_w_h1}" "--failed-only"
assert_contains "H1o. watch --help shows --step focus" "${out_w_h1}" "--step STEP_ID"

# ---------------------------------------------------------------------------
# P2 cases — status symbols + dashboard footer for failed / running runs
# ---------------------------------------------------------------------------

# stage_failed_run_dir <name>: same shape as stage_run_dir but step
# execution_state = "failed" so cmd_watch's failure detection fires.
stage_failed_run_dir() {
  local case_name="$1"
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
      "execution_state": "failed",
      "blocked_reason": "auth_error",
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
  "workflow_name": "Watch Failed Test",
  "sessions": [
    {
      "session_id": "run_${case_name}.1.spec_step",
      "step_id": "spec_step",
      "role": "ba",
      "capability": "specification",
      "executor": "ai",
      "provider": "claude",
      "lifecycle": "completed",
      "result": "failed",
      "duration_seconds": 5
    }
  ]
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: watch-wf
- workflow_name: Watch Failed Test
- run_id: run_${case_name}
- started_at: 2026-05-09 10:00:00

## Steps

### spec_step

- status: failed
- duration_seconds: 5

## Finished

- finished_at: 2026-05-09 10:00:05
- total_duration_seconds: 5
- completed: 0
- failed: 1
- skipped: 0
EOF
  printf '[2026-05-09 10:00:05][step:spec_step][error_type:auth]\n' \
    > "${run_dir}/workflow.log"
  printf '%s|%s' "${cap_home}" "${run_dir}"
}

# stage_running_run_dir <name>: step execution_state = "running",
# run-summary has no Finished block so the builder leaves final_state
# at "running".
stage_running_run_dir() {
  local case_name="$1"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/watch-proj/reports/workflows/watch-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {},
  "steps": {
    "spec_step": {
      "phase": "1",
      "capability": "specification",
      "execution_state": "running",
      "blocked_reason": "",
      "output_source": "",
      "output_path": "",
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
  "workflow_name": "Watch Running Test",
  "sessions": []
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: watch-wf
- run_id: run_${case_name}
- started_at: 2026-05-09 10:00:00

## Steps

### spec_step

- status: running
EOF
  printf '[2026-05-09 10:00:00][step:spec_step][started]\n' \
    > "${run_dir}/workflow.log"
  printf '%s|%s' "${cap_home}" "${run_dir}"
}

# Case 12: failed run compact → ✗ glyph + step-specific logs hint + session inspect
echo "Case 12: --compact on failed run emits failed-step shortcut"
IFS='|' read -r CAP_HOME_12 RUN_DIR_12 <<<"$(stage_failed_run_dir case12)"

set +e
out_12="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact \
  --cap-home "${CAP_HOME_12}" run_case12 2>&1)"
rc_12=$?
set -e

assert_eq "12a. failed compact exit 0" "0" "${rc_12}"
assert_contains "12b. failed header glyph" "${out_12}" "✗ failed"
assert_contains "12c. failed step row glyph" "${out_12}" "✗ spec_step: failed"
assert_contains "12d. failed Next: footer" "${out_12}" "Next:"
assert_contains "12e. failed shortcut names step id" "${out_12}" "cap workflow logs run_case12 --step spec_step"
assert_contains "12f. failed shortcut suggests session inspect" "${out_12}" "cap session inspect --run-id run_case12"
# Failed runs MUST NOT suggest inspect (the dashboard already pinpoints the failure).
assert_not_contains "12g. failed run skips generic inspect hint" "${out_12}" "cap workflow inspect run_case12"

# Case 13: running run compact → ● glyph + watch + logs -f --step hints
echo "Case 13: --compact on running run emits live-tail shortcuts"
IFS='|' read -r CAP_HOME_13 RUN_DIR_13 <<<"$(stage_running_run_dir case13)"

set +e
out_13="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact \
  --cap-home "${CAP_HOME_13}" run_case13 2>&1)"
rc_13=$?
set -e

assert_eq "13a. running compact exit 0" "0" "${rc_13}"
assert_contains "13b. running header glyph" "${out_13}" "● running"
assert_contains "13c. running step row glyph" "${out_13}" "● spec_step: running"
assert_contains "13d. running Next includes watch" "${out_13}" "cap workflow watch run_case13"
assert_contains "13e. running Next includes step-specific logs -f" "${out_13}" "cap workflow logs -f run_case13 --step spec_step"

# Case 14: verbose mode also gets P2 enhancements (glyphs + # Next section + latest_artifact label)
echo "Case 14: verbose mode shows # Next section + latest_artifact label"
IFS='|' read -r CAP_HOME_14 RUN_DIR_14 <<<"$(stage_failed_run_dir case14)"

set +e
out_14="$(bash "${CAP_WORKFLOW_SH}" watch --once \
  --cap-home "${CAP_HOME_14}" run_case14 2>&1)"
rc_14=$?
set -e

assert_eq "14a. verbose failed exit 0" "0" "${rc_14}"
assert_contains "14b. verbose Steps glyph" "${out_14}" "✗ spec_step: failed"
assert_contains "14c. verbose # Next header" "${out_14}" "# Next"
assert_contains "14d. verbose Next has logs --step" "${out_14}" "cap workflow logs run_case14 --step spec_step"
assert_contains "14e. verbose latest_artifact label" "${out_14}" "latest_artifact: spec_doc"

# ---------------------------------------------------------------------------
# Phase 5 cases — --failed-only / --step filters
# ---------------------------------------------------------------------------

# stage_mixed_run_dir <name>: two-step fixture with one ok + one failed
# step so --failed-only / --step filters have meaningful selectivity.
stage_mixed_run_dir() {
  local case_name="$1"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/watch-proj/reports/workflows/watch-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {
    "ok_doc":   {"artifact": "ok_doc",   "source_step": "ok_step",   "path": "/tmp/ok.md"},
    "fail_doc": {"artifact": "fail_doc", "source_step": "fail_step", "path": "/tmp/fail.md"}
  },
  "steps": {
    "ok_step":   {"phase": "1", "capability": "c", "execution_state": "validated", "blocked_reason": "", "output_source": "", "output_path": "/tmp/ok.md", "handoff_path": ""},
    "fail_step": {"phase": "2", "capability": "c", "execution_state": "failed",    "blocked_reason": "auth", "output_source": "", "output_path": "/tmp/fail.md", "handoff_path": ""}
  }
}
EOF
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1,
  "run_id": "run_${case_name}",
  "workflow_id": "watch-wf",
  "workflow_name": "Watch Mixed Test",
  "sessions": [
    {"session_id": "run_${case_name}.1.ok_step", "step_id": "ok_step",
     "role": "ba", "capability": "c", "executor": "ai",
     "provider": "claude", "lifecycle": "completed", "result": "success",
     "duration_seconds": 3},
    {"session_id": "run_${case_name}.2.fail_step", "step_id": "fail_step",
     "role": "ba", "capability": "c", "executor": "ai",
     "provider": "claude", "lifecycle": "completed", "result": "failed",
     "duration_seconds": 2}
  ]
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary

- workflow_id: watch-wf
- run_id: run_${case_name}
- started_at: 2026-05-09 10:00:00

## Steps
### ok_step
- status: ok
### fail_step
- status: failed

## Finished
- finished_at: 2026-05-09 10:00:05
- total_duration_seconds: 5
- completed: 1
- failed: 1
- skipped: 0
EOF
  printf '[2026-05-09 10:00:00][workflow][started]\n[2026-05-09 10:00:03][step:fail_step][failed]\n' \
    > "${run_dir}/workflow.log"
  printf '%s|%s' "${cap_home}" "${run_dir}"
}

# stage_all_ok_run_dir <name>: all steps validated → --failed-only must
# show "(no failed steps)" placeholder, not an empty section.
stage_all_ok_run_dir() {
  local case_name="$1"
  local cap_home="${SANDBOX}/${case_name}/cap"
  local run_dir="${cap_home}/projects/watch-proj/reports/workflows/watch-wf/run_${case_name}"
  mkdir -p "${run_dir}"
  cat > "${run_dir}/runtime-state.json" <<'EOF'
{
  "artifacts": {"ok_doc": {"artifact": "ok_doc", "source_step": "spec_step", "path": "/tmp/ok.md"}},
  "steps": {"spec_step": {"phase": "1", "capability": "specification", "execution_state": "validated", "blocked_reason": "", "output_source": "", "output_path": "", "handoff_path": ""}}
}
EOF
  cat > "${run_dir}/agent-sessions.json" <<EOF
{
  "version": 1, "run_id": "run_${case_name}", "workflow_id": "watch-wf",
  "workflow_name": "All OK", "sessions": [
    {"session_id": "run_${case_name}.1.spec_step", "step_id": "spec_step",
     "role": "ba", "capability": "specification", "executor": "ai",
     "provider": "claude", "lifecycle": "completed", "result": "success",
     "duration_seconds": 3}
  ]
}
EOF
  cat > "${run_dir}/run-summary.md" <<EOF
# Workflow Run Summary
- run_id: run_${case_name}
- started_at: 2026-05-09 10:00:00
## Steps
### spec_step
- status: ok
## Finished
- finished_at: 2026-05-09 10:00:03
- total_duration_seconds: 3
- completed: 1
- failed: 0
- skipped: 0
EOF
  printf '[2026-05-09 10:00:03][workflow][success]\n' > "${run_dir}/workflow.log"
  printf '%s|%s' "${cap_home}" "${run_dir}"
}

# Case 15: --failed-only on a mixed run keeps just the failed entries
echo "Case 15: --failed-only filters mixed run to failed entries"
IFS='|' read -r CAP_HOME_15 RUN_DIR_15 <<<"$(stage_mixed_run_dir case15)"

set +e
out_15="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact --failed-only \
  --cap-home "${CAP_HOME_15}" run_case15 2>&1)"
rc_15=$?
set -e

assert_eq "15a. --failed-only exit 0" "0" "${rc_15}"
assert_contains "15b. shows the failed step row" "${out_15}" "✗ fail_step: failed"
assert_not_contains "15c. drops the ok step from filtered view" "${out_15}" "ok_step:"
# Sessions count reflects filter (1 of 2 sessions)
assert_contains "15d. failed-only sessions count is 1" "${out_15}" "sessions: 1"
# artifacts list filters to failed-step's artifact only
assert_contains "15e. shows fail_doc as latest artifact" "${out_15}" "latest: fail_doc"
assert_not_contains "15f. drops ok_doc from filtered view" "${out_15}" "ok_doc"

# Case 16: --failed-only on an all-ok run shows the placeholder
echo "Case 16: --failed-only on all-ok run shows (no failed steps)"
IFS='|' read -r CAP_HOME_16 RUN_DIR_16 <<<"$(stage_all_ok_run_dir case16)"

set +e
out_16="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact --failed-only \
  --cap-home "${CAP_HOME_16}" run_case16 2>&1)"
rc_16=$?
set -e

assert_eq "16a. --failed-only exit 0 on all-ok" "0" "${rc_16}"
assert_contains "16b. shows (no failed steps) placeholder" "${out_16}" "(no failed steps)"
assert_contains "16c. sessions count drops to 0" "${out_16}" "sessions: 0"
assert_contains "16d. artifacts count drops to 0" "${out_16}" "artifacts: 0"

# Case 17: --step <id> trims to one step
echo "Case 17: --step focus trims payload"
IFS='|' read -r CAP_HOME_17 RUN_DIR_17 <<<"$(stage_mixed_run_dir case17)"

set +e
out_17="$(bash "${CAP_WORKFLOW_SH}" watch --once --compact --step ok_step \
  --cap-home "${CAP_HOME_17}" run_case17 2>&1)"
rc_17=$?
set -e

assert_eq "17a. --step exit 0" "0" "${rc_17}"
assert_contains "17b. shows the focused step" "${out_17}" "✓ ok_step: ok"
assert_not_contains "17c. drops other step" "${out_17}" "fail_step:"
assert_contains "17d. focused sessions count is 1" "${out_17}" "sessions: 1"
assert_contains "17e. focused artifact is ok_doc" "${out_17}" "latest: ok_doc"
assert_not_contains "17f. drops fail_doc artifact" "${out_17}" "fail_doc"

# Case 18: --step missing exits 1 with Chinese stderr
echo "Case 18: --step missing"
IFS='|' read -r CAP_HOME_18 RUN_DIR_18 <<<"$(stage_mixed_run_dir case18)"

set +e
out_18="$(bash "${CAP_WORKFLOW_SH}" watch --once --step ghost_step \
  --cap-home "${CAP_HOME_18}" run_case18 2>&1)"
rc_18=$?
set -e

assert_eq "18a. --step missing exits 1" "1" "${rc_18}"
assert_contains "18b. names missing step (Chinese)" "${out_18}" "找不到 step ghost_step"

# Case 19: --json + --failed-only preserves filter
echo "Case 19: --json + --failed-only filters payload top-level arrays"
IFS='|' read -r CAP_HOME_19 RUN_DIR_19 <<<"$(stage_mixed_run_dir case19)"

set +e
out_19="$(bash "${CAP_WORKFLOW_SH}" watch --json --failed-only \
  --cap-home "${CAP_HOME_19}" run_case19 2>&1)"
rc_19=$?
set -e

assert_eq "19a. --json --failed-only exit 0" "0" "${rc_19}"
counts="$(${PYTHON_BIN} -c '
import json, sys
data = json.loads(sys.stdin.read())
print("steps:", len(data.get("steps", [])))
print("sessions:", len(data.get("sessions", [])))
print("artifacts:", len(data.get("artifacts", [])))
print("filter_marker:", data.get("_filter_failed_only"))
' <<<"${out_19}")"
assert_contains "19b. JSON steps trimmed to 1" "${counts}" "steps: 1"
assert_contains "19c. JSON sessions trimmed to 1" "${counts}" "sessions: 1"
assert_contains "19d. JSON artifacts trimmed to 1" "${counts}" "artifacts: 1"
assert_contains "19e. JSON marks filter active" "${counts}" "filter_marker: True"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
total=$((pass_count + fail_count))
echo "cap-workflow-watch: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
