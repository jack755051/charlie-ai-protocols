#!/usr/bin/env bash
#
# test-agent-session-runner.sh — P5 #1-#3 baseline gate.
#
# Verifies the new additive Python execution layer:
#   engine/provider_adapter.py  (ProviderRequest / ProviderResult /
#                                ProviderAdapter ABC / FakeAdapter /
#                                ShellAdapter)
#   engine/agent_session_runner.py  (AgentSessionRunner orchestrating
#                                    adapter dispatch + ledger writes)
#
# Out of scope (deliberately untested here per P5 baseline §1):
#   - cap-workflow-exec.sh production execution loop is unchanged.
#   - CodexAdapter / ClaudeAdapter not implemented in this batch.
#   - Prompt snapshot / hash, parent / child session relation, and
#     `cap session inspect` belong to later P5 batches.
#
# Coverage (inline-Python, no AI / no network):
#   Case 1 FakeAdapter happy:        runner returns completed; ledger
#                                    file contains a session with
#                                    lifecycle=completed, result=passed.
#   Case 2 FakeAdapter callable:     adapter receives the request and
#                                    can branch per-request.
#   Case 3 FakeAdapter raises:       runner catches adapter exception
#                                    and writes lifecycle=failed with a
#                                    descriptive failure_reason.
#   Case 4 ShellAdapter exit 0:      bash command 'true' → status
#                                    completed, exit_code 0.
#   Case 5 ShellAdapter exit 1:      bash command 'exit 1' → status
#                                    failed, exit_code 1, failure_reason
#                                    surfaces non-zero exit.
#   Case 6 ShellAdapter stdio:       echo to stdout + stderr is captured
#                                    independently in the result.
#   Case 7 ShellAdapter timeout:     `sleep 5` with timeout_seconds=0.5
#                                    → status=timeout, exit_code=-1,
#                                    failure_reason mentions timeout.
#   Case 8 runner + shell ledger:    AgentSessionRunner with ShellAdapter
#                                    writes a ledger entry whose
#                                    duration_seconds is non-empty and
#                                    failure_reason matches the shell
#                                    failure path.
#   Case 9 timeout → lifecycle=failed: timeout result maps to ledger
#                                       lifecycle=failed.
#   Case 10 idempotent upsert:       running run_step twice with the
#                                    same session_id updates the same
#                                    ledger entry rather than appending.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/provider_adapter.py" ] || {
  echo "FAIL: engine/provider_adapter.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/engine/agent_session_runner.py" ] || {
  echo "FAIL: engine/agent_session_runner.py missing"; exit 1;
}

pass_count=0
fail_count=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -5)"
    fail_count=$((fail_count + 1))
  fi
}

run_py() {
  local code="$1"
  ( cd "${REPO_ROOT}" && python3 -c "${code}" 2>&1 )
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: FakeAdapter happy → ledger lifecycle=completed"
out1="$(run_py "
import json, tempfile, pathlib
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='hello', stderr='', duration_seconds=0.005))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai')
    out = AgentSessionRunner().run_step(fa, ProviderRequest(session_id='', step_id='s1', prompt='hi'), ctx)
    data = json.loads(pathlib.Path(sessions).read_text())
    print('outcome_lifecycle=' + out.lifecycle)
    print('outcome_result_status=' + out.result.status)
    print('ledger_count=' + str(len(data['sessions'])))
    print('ledger_lifecycle=' + data['sessions'][0]['lifecycle'])
    print('ledger_result=' + data['sessions'][0]['result'])
    print('ledger_provider_cli=' + data['sessions'][0]['provider_cli'])
")"
assert_contains "outcome lifecycle completed"  "outcome_lifecycle=completed"  "${out1}"
assert_contains "outcome status completed"     "outcome_result_status=completed" "${out1}"
assert_contains "ledger has 1 session"         "ledger_count=1"                 "${out1}"
assert_contains "ledger lifecycle completed"   "ledger_lifecycle=completed"     "${out1}"
assert_contains "ledger result passed"          "ledger_result=passed"           "${out1}"
assert_contains "ledger provider_cli=fake"     "ledger_provider_cli=fake"       "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: FakeAdapter callable receives request"
out2="$(run_py "
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED, STATUS_FAILED
seen = {}
def maker(req):
    seen['session'] = req.session_id
    seen['step'] = req.step_id
    seen['prompt'] = req.prompt
    return ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='ok', stderr='', duration_seconds=0.001)
fa = FakeAdapter(maker)
res = fa.run(ProviderRequest(session_id='sess-A', step_id='step-1', prompt='do work'))
print('callable_session=' + seen['session'])
print('callable_step=' + seen['step'])
print('callable_prompt=' + seen['prompt'])
print('callable_status=' + res.status)
")"
assert_contains "callable saw session_id"  "callable_session=sess-A"  "${out2}"
assert_contains "callable saw step_id"     "callable_step=step-1"     "${out2}"
assert_contains "callable saw prompt"      "callable_prompt=do work"  "${out2}"
assert_contains "callable returned status" "callable_status=completed" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: FakeAdapter raises → runner records failed"
out3="$(run_py "
import json, tempfile, pathlib
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult
from engine.agent_session_runner import AgentSessionRunner, SessionContext
def boom(req):
    raise RuntimeError('synthetic adapter crash')
fa = FakeAdapter(boom)
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf', workflow_name='WF',
                         step_id='sX', capability='cap_x', agent_alias='alias_x', executor='ai')
    out = AgentSessionRunner().run_step(fa, ProviderRequest(session_id='', step_id='sX', prompt='hi'), ctx)
    data = json.loads(pathlib.Path(sessions).read_text())
    print('outcome_lifecycle=' + out.lifecycle)
    print('outcome_failure=' + (out.failure_reason or ''))
    print('ledger_lifecycle=' + data['sessions'][0]['lifecycle'])
    print('ledger_failure=' + (data['sessions'][0].get('failure_reason') or ''))
")"
assert_contains "outcome lifecycle failed" "outcome_lifecycle=failed" "${out3}"
assert_contains "outcome failure mentions adapter exception" "synthetic adapter crash" "${out3}"
assert_contains "ledger lifecycle failed"  "ledger_lifecycle=failed"  "${out3}"
assert_contains "ledger failure populated" "RuntimeError"             "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: ShellAdapter exit 0 → completed"
out4="$(run_py "
from engine.provider_adapter import ShellAdapter, ProviderRequest
res = ShellAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='true'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
")"
assert_contains "shell exit 0 status completed" "status=completed" "${out4}"
assert_contains "shell exit 0 exit_code 0"       "exit=0"           "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: ShellAdapter exit 1 → failed with failure_reason"
out5="$(run_py "
from engine.provider_adapter import ShellAdapter, ProviderRequest
res = ShellAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='exit 1'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "shell exit 1 status failed"  "status=failed"            "${out5}"
assert_contains "shell exit 1 exit_code 1"    "exit=1"                   "${out5}"
assert_contains "failure mentions exit code"  "shell command exited 1"   "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: ShellAdapter stdout/stderr captured separately"
out6="$(run_py "
from engine.provider_adapter import ShellAdapter, ProviderRequest
res = ShellAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='echo to-out; echo to-err 1>&2'))
print('stdout=' + res.stdout.strip())
print('stderr=' + res.stderr.strip())
print('status=' + res.status)
")"
assert_contains "stdout captured"  "stdout=to-out"  "${out6}"
assert_contains "stderr captured"  "stderr=to-err"  "${out6}"
assert_contains "still completed"  "status=completed" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: ShellAdapter timeout → status=timeout, exit=-1"
out7="$(run_py "
from engine.provider_adapter import ShellAdapter, ProviderRequest
res = ShellAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='sleep 5', timeout_seconds=0.5))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "timeout status"          "status=timeout"   "${out7}"
assert_contains "timeout exit -1"         "exit=-1"          "${out7}"
assert_contains "failure mentions timeout" "timed out"        "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: runner + ShellAdapter writes ledger entry with duration"
out8="$(run_py "
import json, tempfile, pathlib
from engine.provider_adapter import ShellAdapter, ProviderRequest
from engine.agent_session_runner import AgentSessionRunner, SessionContext
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf', workflow_name='WF',
                         step_id='shell-step', capability='shell_op', agent_alias='shell-runner',
                         executor='shell')
    runner = AgentSessionRunner()
    out_ok = runner.run_step(ShellAdapter(),
                             ProviderRequest(session_id='', step_id='shell-step', prompt='true'),
                             ctx)
    out_fail = runner.run_step(ShellAdapter(),
                               ProviderRequest(session_id='', step_id='shell-step-2', prompt='exit 7'),
                               SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf',
                                              workflow_name='WF', step_id='shell-step-2',
                                              capability='shell_op', agent_alias='shell-runner',
                                              executor='shell'))
    data = json.loads(pathlib.Path(sessions).read_text())
    by_step = {s['step_id']: s for s in data['sessions']}
    ok = by_step['shell-step']
    bad = by_step['shell-step-2']
    print('ok_lifecycle=' + ok['lifecycle'])
    # step_runtime.upsert_session stores duration as integer seconds; sub-second
    # adapter calls round to 0 — we just assert the field landed (not None).
    print('ok_duration_present=' + str(ok.get('duration_seconds') is not None))
    print('bad_lifecycle=' + bad['lifecycle'])
    print('bad_failure=' + (bad.get('failure_reason') or ''))
    print('bad_provider_cli=' + bad['provider_cli'])
")"
assert_contains "ok lifecycle completed"  "ok_lifecycle=completed"           "${out8}"
assert_contains "duration_seconds set"     "ok_duration_present=True"         "${out8}"
assert_contains "failed lifecycle"         "bad_lifecycle=failed"             "${out8}"
assert_contains "failure surfaces exit 7"  "shell command exited 7"           "${out8}"
assert_contains "shell adapter name"       "bad_provider_cli=shell"           "${out8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: timeout result → ledger lifecycle=failed"
out9="$(run_py "
import json, tempfile, pathlib
from engine.provider_adapter import ShellAdapter, ProviderRequest
from engine.agent_session_runner import AgentSessionRunner, SessionContext
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf', workflow_name='WF',
                         step_id='timeout-step', capability='shell_op', agent_alias='shell-runner',
                         executor='shell')
    out = AgentSessionRunner().run_step(
        ShellAdapter(),
        ProviderRequest(session_id='', step_id='timeout-step', prompt='sleep 5', timeout_seconds=0.4),
        ctx,
    )
    data = json.loads(pathlib.Path(sessions).read_text())
    s = data['sessions'][0]
    print('status=' + out.result.status)
    print('lifecycle=' + s['lifecycle'])
    print('failure=' + (s.get('failure_reason') or ''))
")"
assert_contains "result status timeout"     "status=timeout"   "${out9}"
assert_contains "ledger lifecycle failed"   "lifecycle=failed" "${out9}"
assert_contains "failure mentions timeout"  "timed out"        "${out9}"

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: same session_id → ledger entry updated (not duplicated)"
out10="$(run_py "
import json, tempfile, pathlib
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='ok', stderr='', duration_seconds=0.001))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r1', workflow_id='wf', workflow_name='WF',
                         step_id='same-id', capability='cap_x', agent_alias='alias_x', executor='ai')
    runner = AgentSessionRunner()
    runner.run_step(fa, ProviderRequest(session_id='sess-fixed', step_id='same-id', prompt='hi'), ctx)
    runner.run_step(fa, ProviderRequest(session_id='sess-fixed', step_id='same-id', prompt='hi-again'), ctx)
    data = json.loads(pathlib.Path(sessions).read_text())
    print('count=' + str(len(data['sessions'])))
    print('only_id=' + data['sessions'][0]['session_id'])
")"
assert_contains "single ledger entry" "count=1"                 "${out10}"
assert_contains "kept the fixed id"   "only_id=sess-fixed"      "${out10}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "agent-session-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
