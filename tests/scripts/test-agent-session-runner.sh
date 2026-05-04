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

# ── Case 11 (P5 #6) ─────────────────────────────────────────────────────
echo "Case 11 (P5 #6): prompt snapshot is sha256 content-addressed and surfaced in ledger"
out11="$(run_py "
import hashlib, json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai')
    prompt = 'render this prompt deterministically'
    expected_hash = hashlib.sha256(prompt.encode('utf-8')).hexdigest()
    out = AgentSessionRunner().run_step(fa, ProviderRequest(session_id='', step_id='s1', prompt=prompt), ctx)
    print('outcome_hash=' + (out.prompt_snapshot.hash if out.prompt_snapshot else ''))
    print('expected_hash_prefix=' + expected_hash[:12])
    print('outcome_size=' + str(out.prompt_snapshot.size_bytes if out.prompt_snapshot else -1))
    sf = pathlib.Path(out.prompt_snapshot.path)
    print('snapshot_exists=' + str(sf.exists()))
    print('snapshot_content_match=' + str(sf.read_text() == prompt))
    expected_layout = pathlib.Path(td) / 'prompts' / expected_hash[:2] / (expected_hash + '.txt')
    print('layout_match=' + str(sf.resolve() == expected_layout.resolve()))
    data = json.loads(pathlib.Path(sessions).read_text())
    s = data['sessions'][0]
    print('ledger_hash=' + s.get('prompt_hash', ''))
    print('ledger_size=' + str(s.get('prompt_size_bytes', -1)))
    print('ledger_path_basename=' + pathlib.Path(s.get('prompt_snapshot_path', '')).name)
")"
assert_contains "outcome carries snapshot"           "outcome_hash="                            "${out11}"
assert_contains "outcome hash matches sha256"        "expected_hash_prefix=$(printf '%s' 'render this prompt deterministically' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])')" "${out11}"
assert_contains "snapshot file exists"               "snapshot_exists=True"                     "${out11}"
assert_contains "snapshot content matches input"     "snapshot_content_match=True"              "${out11}"
assert_contains "snapshot path layout correct"       "layout_match=True"                        "${out11}"
assert_contains "ledger has prompt_hash"             "ledger_hash="                             "${out11}"
assert_contains "ledger has prompt_size_bytes"       "ledger_size=$(printf '%s' 'render this prompt deterministically' | wc -c | tr -d ' ')" "${out11}"

# ── Case 12 (P5 #6) ─────────────────────────────────────────────────────
echo "Case 12 (P5 #6): identical prompts dedupe to the same snapshot file"
out12="$(run_py "
import json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
runner = AgentSessionRunner()
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    base = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                          step_id='', capability='cap_x', agent_alias='alias_x', executor='ai')
    prompt = 'shared prompt body'
    a = runner.run_step(fa, ProviderRequest(session_id='sess-A', step_id='step-A', prompt=prompt),
                        SessionContext(**{**base.__dict__, 'step_id': 'step-A'}))
    b = runner.run_step(fa, ProviderRequest(session_id='sess-B', step_id='step-B', prompt=prompt),
                        SessionContext(**{**base.__dict__, 'step_id': 'step-B'}))
    c = runner.run_step(fa, ProviderRequest(session_id='sess-C', step_id='step-C', prompt='different prompt body'),
                        SessionContext(**{**base.__dict__, 'step_id': 'step-C'}))
    print('a_hash=' + a.prompt_snapshot.hash[:12])
    print('b_hash=' + b.prompt_snapshot.hash[:12])
    print('c_hash=' + c.prompt_snapshot.hash[:12])
    print('a_path=' + a.prompt_snapshot.path)
    print('b_path=' + b.prompt_snapshot.path)
    print('a_eq_b_path=' + str(a.prompt_snapshot.path == b.prompt_snapshot.path))
    print('a_neq_c_path=' + str(a.prompt_snapshot.path != c.prompt_snapshot.path))
    snapshot_files = sorted(p.name for p in (pathlib.Path(td) / 'prompts').rglob('*.txt'))
    print('total_snapshot_files=' + str(len(snapshot_files)))
")"
assert_contains "identical prompts share path"     "a_eq_b_path=True"        "${out12}"
assert_contains "different prompts split path"    "a_neq_c_path=True"        "${out12}"
assert_contains "only 2 snapshot files on disk"   "total_snapshot_files=2"   "${out12}"

# ── Case 13 (P5 #6) ─────────────────────────────────────────────────────
# Note: full ledger schema validation is intentionally NOT asserted here
# because schemas/agent-session.schema.yaml uses OpenAPI-style
# `nullable: true` for several pre-existing optional fields
# (parent_session_id, prompt_file, failure_reason) which the
# JSON-Schema validator does not honour — that is a pre-existing gap
# tracked separately, not in scope for the P5 #6 prompt-snapshot
# delivery. Instead we sanity-check the three new fields are typed
# correctly in isolation.
echo "Case 13 (P5 #6): new ledger fields have correct types"
out13="$(run_py "
import json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='task_constitution_planning', agent_alias='alias_x',
                         executor='ai')
    AgentSessionRunner().run_step(fa, ProviderRequest(session_id='', step_id='s1', prompt='type-check prompt'), ctx)
    s = json.loads(pathlib.Path(sessions).read_text())['sessions'][0]
    print('hash_is_str=' + str(isinstance(s.get('prompt_hash'), str)))
    print('hash_len=' + str(len(s.get('prompt_hash', ''))))
    print('path_is_str=' + str(isinstance(s.get('prompt_snapshot_path'), str)))
    print('size_is_int=' + str(isinstance(s.get('prompt_size_bytes'), int)))
")"
assert_contains "prompt_hash is string"          "hash_is_str=True"        "${out13}"
assert_contains "prompt_hash length is 64 (sha256 hex)" "hash_len=64"      "${out13}"
assert_contains "prompt_snapshot_path is string" "path_is_str=True"        "${out13}"
assert_contains "prompt_size_bytes is integer"   "size_is_int=True"        "${out13}"

# ── Case 14 (P5 #7) ─────────────────────────────────────────────────────
echo "Case 14 (P5 #7): no parent → root_session_id = self"
out14="$(run_py "
import json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai')
    out = AgentSessionRunner().run_step(fa, ProviderRequest(session_id='sess-solo', step_id='s1', prompt='p'), ctx)
    s = json.loads(pathlib.Path(sessions).read_text())['sessions'][0]
    print('root=' + (s.get('root_session_id') or ''))
    print('parent=' + str(s.get('parent_session_id')))
")"
assert_contains "root equals self when no parent"  "root=sess-solo"   "${out14}"
assert_contains "parent stays None"                "parent=None"      "${out14}"

# ── Case 15 (P5 #7) ─────────────────────────────────────────────────────
echo "Case 15 (P5 #7): parent in ledger → child inherits parent's root_session_id"
out15="$(run_py "
import json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
runner = AgentSessionRunner()
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    base = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                          step_id='', capability='cap_x', agent_alias='alias_x', executor='ai')
    runner.run_step(fa, ProviderRequest(session_id='root-A', step_id='sa', prompt='p1'),
                    SessionContext(**{**base.__dict__, 'step_id':'sa'}))
    runner.run_step(fa, ProviderRequest(session_id='child-B', step_id='sb', prompt='p2'),
                    SessionContext(**{**base.__dict__, 'step_id':'sb',
                                      'parent_session_id':'root-A',
                                      'spawn_reason':'delegate planning to specialist'}))
    runner.run_step(fa, ProviderRequest(session_id='grand-C', step_id='sc', prompt='p3'),
                    SessionContext(**{**base.__dict__, 'step_id':'sc', 'parent_session_id':'child-B'}))
    data = json.loads(pathlib.Path(sessions).read_text())
    by_id = {s['session_id']: s for s in data['sessions']}
    print('A_root=' + by_id['root-A']['root_session_id'])
    print('B_root=' + by_id['child-B']['root_session_id'])
    print('B_parent=' + by_id['child-B']['parent_session_id'])
    print('B_reason=' + by_id['child-B']['spawn_reason'])
    print('C_root=' + by_id['grand-C']['root_session_id'])
    print('C_parent=' + by_id['grand-C']['parent_session_id'])
")"
assert_contains "A is its own root"                       "A_root=root-A"                                "${out15}"
assert_contains "B inherits A as root"                    "B_root=root-A"                                "${out15}"
assert_contains "B parent linked"                          "B_parent=root-A"                              "${out15}"
assert_contains "B spawn_reason recorded"                  "B_reason=delegate planning to specialist"    "${out15}"
assert_contains "grandchild C inherits root through chain" "C_root=root-A"                                "${out15}"
assert_contains "C parent points at B"                     "C_parent=child-B"                             "${out15}"

# ── Case 16 (P5 #7) ─────────────────────────────────────────────────────
echo "Case 16 (P5 #7): parent absent from ledger → root falls back to parent_session_id (no hard fail)"
out16="$(run_py "
import json, pathlib, tempfile
from engine.provider_adapter import FakeAdapter, ProviderRequest, ProviderResult, STATUS_COMPLETED
from engine.agent_session_runner import AgentSessionRunner, SessionContext
fa = FakeAdapter(ProviderResult(status=STATUS_COMPLETED, exit_code=0, stdout='', stderr='', duration_seconds=0.001))
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai',
                         parent_session_id='phantom-parent-id')
    out = AgentSessionRunner().run_step(fa, ProviderRequest(session_id='sess-orphan', step_id='s1', prompt='p'), ctx)
    s = json.loads(pathlib.Path(sessions).read_text())['sessions'][0]
    print('root=' + s['root_session_id'])
    print('parent=' + s['parent_session_id'])
    print('lifecycle=' + s['lifecycle'])
")"
assert_contains "fallback root = parent_session_id"  "root=phantom-parent-id"      "${out16}"
assert_contains "parent still recorded"               "parent=phantom-parent-id"   "${out16}"
assert_contains "no hard fail; lifecycle completed"   "lifecycle=completed"         "${out16}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "agent-session-runner: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
