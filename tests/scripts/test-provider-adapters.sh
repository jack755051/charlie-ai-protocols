#!/usr/bin/env bash
#
# test-provider-adapters.sh — P5 #3 (CodexAdapter) + P5 #4 (ClaudeAdapter) gate.
#
# Verifies engine.provider_adapter.CodexAdapter against fake codex
# binaries placed in a sandbox. No real provider is invoked — every
# scenario is driven by a small bash script that mimics the codex CLI
# output shape (banner / user transcript / assistant marker /
# response). Mirrors the production shell wrapper at
# scripts/cap-workflow-exec.sh:run_step_codex semantically without
# touching it.
#
# Coverage:
#   Case 1 happy + preamble strip: fake codex emits banner + user
#                                  transcript + assistant marker +
#                                  response → adapter returns status
#                                  completed and stdout = cleaned
#                                  response only.
#   Case 2 stderr separation:      fake codex writes to both streams →
#                                  stdout / stderr captured apart.
#   Case 3 no marker fallback:     fake codex emits raw output without
#                                  the assistant marker → adapter falls
#                                  back to the raw stdout.
#   Case 4 non-zero exit:          fake codex exits 7 → status=failed,
#                                  exit_code=7, failure_reason names the
#                                  exit code.
#   Case 5 timeout:                fake codex sleeps; timeout=0.5 →
#                                  status=timeout, exit_code=-1,
#                                  failure_reason carries the
#                                  P5 #9 'timeout:' prefix.
#   Case 6 --skip-git-repo-check:  fake codex echoes its argv → adapter
#                                  command line includes
#                                  'exec --skip-git-repo-check' before
#                                  the prompt by default; constructor
#                                  flag opts out.
#   Case 7 missing binary:         CAP_CODEX_BIN points at a
#                                  non-existent path → adapter returns
#                                  deterministic failed result without
#                                  raising.
#   Case 8 runner integration:     AgentSessionRunner + CodexAdapter
#                                  ledger entry has provider_cli="codex"
#                                  and lifecycle=completed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/provider_adapter.py" ] || {
  echo "FAIL: engine/provider_adapter.py missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-provider-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

mkdir -p "${SANDBOX}/bin"

cat > "${SANDBOX}/bin/codex-happy" <<'EOF'
#!/bin/bash
echo "==== codex banner ===="
echo "user"
echo "input echo"
echo "assistant"
echo "the cleaned response"
exit 0
EOF
cat > "${SANDBOX}/bin/codex-stderr" <<'EOF'
#!/bin/bash
echo "out-line"
echo "err-line" 1>&2
echo "assistant"
echo "after-stderr"
exit 0
EOF
cat > "${SANDBOX}/bin/codex-no-marker" <<'EOF'
#!/bin/bash
echo "raw output without marker"
exit 0
EOF
cat > "${SANDBOX}/bin/codex-fail" <<'EOF'
#!/bin/bash
echo "partial assistant content" 1>&2
exit 7
EOF
cat > "${SANDBOX}/bin/codex-slow" <<'EOF'
#!/bin/bash
sleep 5
EOF
cat > "${SANDBOX}/bin/claude-happy" <<'EOF'
#!/bin/bash
echo "claude clean response"
exit 0
EOF
cat > "${SANDBOX}/bin/claude-stderr" <<'EOF'
#!/bin/bash
echo "out-line"
echo "err-line" 1>&2
exit 0
EOF
cat > "${SANDBOX}/bin/claude-fail" <<'EOF'
#!/bin/bash
echo "claude said no" 1>&2
exit 5
EOF
cat > "${SANDBOX}/bin/claude-slow" <<'EOF'
#!/bin/bash
sleep 5
EOF
cat > "${SANDBOX}/bin/claude-argecho" <<'EOF'
#!/bin/bash
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
exit 0
EOF
cat > "${SANDBOX}/bin/codex-argecho" <<'EOF'
#!/bin/bash
# Place argc/args inside the assistant block so the adapter's preamble
# stripper retains them and the test can read them off cleaned stdout.
echo "==== codex banner ===="
echo "assistant"
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
exit 0
EOF
chmod +x "${SANDBOX}/bin/"*

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

run_py_with_codex_bin() {
  local fake="$1"; shift
  local code="$1"; shift
  ( cd "${REPO_ROOT}" && CAP_CODEX_BIN="${fake}" python3 -c "${code}" 2>&1 )
}

run_py_with_claude_bin() {
  local fake="$1"; shift
  local code="$1"; shift
  ( cd "${REPO_ROOT}" && CAP_CLAUDE_BIN="${fake}" python3 -c "${code}" 2>&1 )
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: happy path → preamble stripped to assistant block"
out1="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-happy" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('stdout_repr=' + repr(res.stdout))
")"
assert_contains "status completed"             "status=completed"                   "${out1}"
assert_contains "exit code 0"                  "exit=0"                             "${out1}"
assert_contains "preamble removed"             "stdout_repr='the cleaned response\n'"  "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: stdout / stderr captured separately"
out2="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-stderr" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('stdout=' + res.stdout.strip())
print('stderr=' + res.stderr.strip())
")"
assert_contains "stdout cleaned to assistant block"  "stdout=after-stderr"  "${out2}"
assert_contains "stderr captured separately"          "stderr=err-line"      "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: no assistant marker → raw stdout fallback"
out3="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-no-marker" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('stdout=' + res.stdout.strip())
print('status=' + res.status)
")"
assert_contains "fallback returns raw stdout"  "stdout=raw output without marker"  "${out3}"
assert_contains "still completed on exit 0"    "status=completed"                  "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: non-zero exit → failed with exit_code captured"
out4="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-fail" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "status failed"            "status=failed"      "${out4}"
assert_contains "exit code 7 captured"     "exit=7"             "${out4}"
assert_contains "failure mentions exit 7"  "codex exited 7"     "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: timeout → status=timeout with P5 #9 prefix"
out5="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-slow" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi', timeout_seconds=0.5))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "timeout status"               "status=timeout"                       "${out5}"
assert_contains "timeout exit -1"              "exit=-1"                              "${out5}"
assert_contains "failure has timeout: prefix"  "timeout: codex command exceeded 0.5s" "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: default constructor passes 'exec --skip-git-repo-check <prompt>'"
out6="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-argecho" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='HELLO_PROMPT'))
print(res.stdout)
")"
assert_contains "argc=3 (exec + flag + prompt)"  "argc=3"                       "${out6}"
assert_contains "exec subcommand passed"          "arg=exec"                     "${out6}"
assert_contains "skip-git-repo-check passed"      "arg=--skip-git-repo-check"    "${out6}"
assert_contains "prompt passed last"              "arg=HELLO_PROMPT"             "${out6}"

echo "Case 6b: skip_git_repo_check=False omits the flag"
out6b="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-argecho" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter(skip_git_repo_check=False).run(ProviderRequest(session_id='x', step_id='s', prompt='HELLO_PROMPT'))
print(res.stdout)
")"
assert_contains "argc=2 when flag omitted"   "argc=2"                "${out6b}"
assert_contains "no skip flag"               "arg=HELLO_PROMPT"      "${out6b}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: missing codex binary → deterministic failed result, no raise"
out7="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-NOT-A-FILE" "
from engine.provider_adapter import CodexAdapter, ProviderRequest
res = CodexAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "status failed not raised"  "status=failed"   "${out7}"
assert_contains "failure mentions binary"   "codex binary"    "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: AgentSessionRunner + CodexAdapter writes ledger with provider_cli=codex"
out8="$(run_py_with_codex_bin "${SANDBOX}/bin/codex-happy" "
import json, tempfile, pathlib
from engine.provider_adapter import CodexAdapter, ProviderRequest
from engine.agent_session_runner import AgentSessionRunner, SessionContext
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai')
    out = AgentSessionRunner().run_step(CodexAdapter(),
                                        ProviderRequest(session_id='', step_id='s1', prompt='p'),
                                        ctx)
    s = json.loads(pathlib.Path(sessions).read_text())['sessions'][0]
    print('outcome_lifecycle=' + out.lifecycle)
    print('outcome_status=' + out.result.status)
    print('ledger_provider_cli=' + s['provider_cli'])
    print('ledger_lifecycle=' + s['lifecycle'])
")"
assert_contains "outcome lifecycle completed"  "outcome_lifecycle=completed"  "${out8}"
assert_contains "result status completed"      "outcome_status=completed"     "${out8}"
assert_contains "ledger provider_cli=codex"    "ledger_provider_cli=codex"    "${out8}"
assert_contains "ledger lifecycle completed"   "ledger_lifecycle=completed"   "${out8}"

# ── Case 9 (P5 #4) ──────────────────────────────────────────────────────
echo "Case 9 (P5 #4): ClaudeAdapter happy path → completed, stdout direct (no preamble)"
out9="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-happy" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('stdout_repr=' + repr(res.stdout))
")"
assert_contains "claude status completed"  "status=completed"                      "${out9}"
assert_contains "claude exit 0"            "exit=0"                                "${out9}"
assert_contains "claude stdout direct"     "stdout_repr='claude clean response\n'" "${out9}"

# ── Case 10 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 10 (P5 #4): ClaudeAdapter stdout / stderr captured separately"
out10="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-stderr" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('stdout=' + res.stdout.strip())
print('stderr=' + res.stderr.strip())
")"
assert_contains "claude stdout captured"  "stdout=out-line"  "${out10}"
assert_contains "claude stderr captured"  "stderr=err-line"  "${out10}"

# ── Case 11 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 11 (P5 #4): ClaudeAdapter non-zero exit → failed with exit_code captured"
out11="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-fail" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "claude status failed"        "status=failed"      "${out11}"
assert_contains "claude exit 5 captured"      "exit=5"             "${out11}"
assert_contains "claude failure mentions exit" "claude exited 5"   "${out11}"

# ── Case 12 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 12 (P5 #4): ClaudeAdapter timeout → status=timeout with P5 #9 prefix"
out12="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-slow" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi', timeout_seconds=0.5))
print('status=' + res.status)
print('exit=' + str(res.exit_code))
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "claude timeout status"             "status=timeout"                        "${out12}"
assert_contains "claude timeout exit -1"            "exit=-1"                               "${out12}"
assert_contains "claude failure has timeout: prefix" "timeout: claude command exceeded 0.5s" "${out12}"

# ── Case 13 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 13 (P5 #4): ClaudeAdapter passes 'claude -p <prompt>' (no extra subcommand)"
out13="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-argecho" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='HELLO_PROMPT'))
print(res.stdout)
")"
assert_contains "argc=2 (-p + prompt only)"  "argc=2"             "${out13}"
assert_contains "-p flag present"             "arg=-p"             "${out13}"
assert_contains "prompt passed last"          "arg=HELLO_PROMPT"   "${out13}"

# ── Case 14 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 14 (P5 #4): ClaudeAdapter missing binary → deterministic failed result"
out14="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-NOT-A-FILE" "
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
res = ClaudeAdapter().run(ProviderRequest(session_id='x', step_id='s', prompt='hi'))
print('status=' + res.status)
print('failure=' + (res.failure_reason or ''))
")"
assert_contains "claude status failed not raised"  "status=failed"   "${out14}"
assert_contains "claude failure mentions binary"   "claude binary"   "${out14}"

# ── Case 15 (P5 #4) ─────────────────────────────────────────────────────
echo "Case 15 (P5 #4): AgentSessionRunner + ClaudeAdapter writes ledger with provider_cli=claude"
out15="$(run_py_with_claude_bin "${SANDBOX}/bin/claude-happy" "
import json, tempfile, pathlib
from engine.provider_adapter import ClaudeAdapter, ProviderRequest
from engine.agent_session_runner import AgentSessionRunner, SessionContext
with tempfile.TemporaryDirectory() as td:
    sessions = str(pathlib.Path(td) / 'agent-sessions.json')
    ctx = SessionContext(sessions_path=sessions, run_id='r', workflow_id='wf', workflow_name='WF',
                         step_id='s1', capability='cap_x', agent_alias='alias_x', executor='ai')
    out = AgentSessionRunner().run_step(ClaudeAdapter(),
                                        ProviderRequest(session_id='', step_id='s1', prompt='p'),
                                        ctx)
    s = json.loads(pathlib.Path(sessions).read_text())['sessions'][0]
    print('outcome_lifecycle=' + out.lifecycle)
    print('ledger_provider_cli=' + s['provider_cli'])
    print('ledger_lifecycle=' + s['lifecycle'])
")"
assert_contains "claude outcome lifecycle completed" "outcome_lifecycle=completed"   "${out15}"
assert_contains "claude ledger provider_cli"          "ledger_provider_cli=claude"    "${out15}"
assert_contains "claude ledger lifecycle"             "ledger_lifecycle=completed"    "${out15}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "provider-adapters: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
