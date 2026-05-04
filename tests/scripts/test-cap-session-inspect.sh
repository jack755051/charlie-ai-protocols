#!/usr/bin/env bash
#
# test-cap-session-inspect.sh — P5 #10 gate.
#
# Verifies engine.session_inspector and the cap session inspect shell
# wrapper render the agent-sessions.json ledger entries with all the
# fields P5 added in earlier batches (lifecycle, prompt snapshot,
# parent / root chain, spawn reason, provider / cli, outputs) and
# surface a deterministic JSON error on miss.
#
# Coverage (hermetic — uses --sessions-path to pin a fixture file):
#   Case 1 text mode happy:        inspect <id> on a populated ledger
#                                  returns exit 0 with all section
#                                  headers present.
#   Case 2 JSON mode happy:        --json returns parseable envelope
#                                  {ok: true, count: 1, sessions[]} and
#                                  surfaces every key the runner writes.
#   Case 3 missing session:        non-existent session_id returns exit
#                                  1 with deterministic JSON error
#                                  {"ok": false, "error":
#                                  "session_not_found", "query": {...}}.
#   Case 4 by run_id:              --run-id returns all sessions in the
#                                  run; multi-match handled.
#   Case 5 by step_id:             --step-id filter works alongside JSON.
#   Case 6 prompt snapshot fields: text rendering shows prompt_hash /
#                                  prompt_snapshot_path / prompt_size_bytes.
#   Case 7 parent / root fields:   text rendering shows parent_session_id
#                                  / root_session_id / spawn_reason.
#   Case 8 cap-entry routing:      cap session inspect (via cap-entry.sh
#                                  → cap-session.sh dispatcher) reaches
#                                  the inspector.
#   Case 9 usage error:            inspect with no positional and no
#                                  filter exits non-zero with usage.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/session_inspector.py" ] || {
  echo "FAIL: engine/session_inspector.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/scripts/cap-session.sh" ] || {
  echo "FAIL: scripts/cap-session.sh missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-sess-inspect-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

FIXTURE="${SANDBOX}/agent-sessions.json"
cat > "${FIXTURE}" <<'EOF'
{
  "run_id": "run-2026-A",
  "workflow_id": "wf-spec",
  "workflow_name": "Spec Pipeline",
  "sessions": [
    {
      "session_id": "sess-prd-001",
      "run_id": "run-2026-A",
      "workflow_id": "wf-spec",
      "workflow_name": "Spec Pipeline",
      "step_id": "prd",
      "parent_session_id": null,
      "root_session_id": "sess-prd-001",
      "spawn_reason": null,
      "role": "prd-bot",
      "capability": "prd_generation",
      "provider": "claude",
      "provider_cli": "claude",
      "executor": "ai",
      "lifecycle": "completed",
      "result": "passed",
      "duration_seconds": 12,
      "failure_reason": null,
      "prompt_hash": "abc123def456",
      "prompt_snapshot_path": "/tmp/prompts/ab/abc123def456.txt",
      "prompt_size_bytes": 2048,
      "inputs": [],
      "outputs": [
        {"artifact": "step_output", "path": "/tmp/run-2026-A/prd/output.md", "promoted": false}
      ],
      "scratch_paths": []
    },
    {
      "session_id": "sess-tech-002",
      "run_id": "run-2026-A",
      "workflow_id": "wf-spec",
      "workflow_name": "Spec Pipeline",
      "step_id": "tech",
      "parent_session_id": "sess-prd-001",
      "root_session_id": "sess-prd-001",
      "spawn_reason": "delegate technical planning to specialist",
      "role": "tech-bot",
      "capability": "tech_planning",
      "provider": "codex",
      "provider_cli": "codex",
      "executor": "ai",
      "lifecycle": "failed",
      "result": "failed",
      "duration_seconds": 5,
      "failure_reason": "timeout: provider X exceeded 30s",
      "prompt_hash": "def789ghi012",
      "prompt_snapshot_path": "/tmp/prompts/de/def789ghi012.txt",
      "prompt_size_bytes": 1024,
      "inputs": [],
      "outputs": [],
      "scratch_paths": []
    }
  ]
}
EOF

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

CAP_SESSION="${REPO_ROOT}/scripts/cap-session.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: text-mode inspect <session_id> renders all sections"
out1="$(bash "${CAP_SESSION}" inspect sess-prd-001 --sessions-path "${FIXTURE}" 2>&1)"
exit1=$?
assert_eq        "exit 0 happy path"            "0"                              "${exit1}"
assert_contains "session_id header rendered"   "session_id: sess-prd-001"        "${out1}"
assert_contains "lifecycle line"               "lifecycle: completed"            "${out1}"
assert_contains "provider with cli label"      "provider: claude (cli=claude)"   "${out1}"
assert_contains "relations section"            "relations:"                      "${out1}"
assert_contains "prompt_snapshot section"      "prompt_snapshot:"                "${out1}"
assert_contains "outputs section"              "outputs:"                        "${out1}"
assert_contains "source_ledger trailer"        "source_ledger: ${FIXTURE}"       "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: --json envelope is machine-parseable"
out2="$(bash "${CAP_SESSION}" inspect sess-prd-001 --sessions-path "${FIXTURE}" --json 2>&1)"
exit2=$?
assert_eq "exit 0 json mode" "0" "${exit2}"
parsed="$(printf '%s' "${out2}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is True, 'ok'
assert d['count'] == 1, 'count'
s = d['sessions'][0]
print('session_id=' + s['session_id'])
print('prompt_hash=' + s['prompt_hash'])
print('lifecycle=' + s['lifecycle'])
print('provider_cli=' + s['provider_cli'])
print('source_present=' + str('_source_path' in s))
")"
assert_contains "json session_id"   "session_id=sess-prd-001"  "${parsed}"
assert_contains "json prompt_hash"  "prompt_hash=abc123def456" "${parsed}"
assert_contains "json lifecycle"    "lifecycle=completed"      "${parsed}"
assert_contains "json provider_cli" "provider_cli=claude"      "${parsed}"
assert_contains "json _source_path annotated" "source_present=True" "${parsed}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: missing session → exit 1 with deterministic JSON error"
out3="$(bash "${CAP_SESSION}" inspect sess-DOES-NOT-EXIST --sessions-path "${FIXTURE}" 2>&1)"
exit3=$?
assert_eq        "exit 1 on miss"               "1"                                              "${exit3}"
assert_contains "deterministic error tag"      "\"error\": \"session_not_found\""               "${out3}"
assert_contains "query echoed back"             "\"session_id\": \"sess-DOES-NOT-EXIST\""        "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: --run-id filter returns multiple sessions"
out4="$(bash "${CAP_SESSION}" inspect --run-id run-2026-A --sessions-path "${FIXTURE}" --json 2>&1)"
parsed4="$(printf '%s' "${out4}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('count=' + str(d['count']))
print('ids=' + ','.join(s['session_id'] for s in d['sessions']))
")"
assert_contains "two sessions for run"  "count=2"                                "${parsed4}"
assert_contains "both ids returned"     "ids=sess-prd-001,sess-tech-002"         "${parsed4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: --step-id filter narrows to one session"
out5="$(bash "${CAP_SESSION}" inspect --step-id tech --sessions-path "${FIXTURE}" --json 2>&1)"
parsed5="$(printf '%s' "${out5}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('count=' + str(d['count']))
print('id=' + d['sessions'][0]['session_id'])
print('failure=' + d['sessions'][0]['failure_reason'])
")"
assert_contains "step filter narrows"        "count=1"                              "${parsed5}"
assert_contains "tech session id"            "id=sess-tech-002"                     "${parsed5}"
assert_contains "failure_reason carried"     "failure=timeout: provider X exceeded 30s" "${parsed5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: text rendering surfaces prompt snapshot fields"
out6="$(bash "${CAP_SESSION}" inspect sess-prd-001 --sessions-path "${FIXTURE}" 2>&1)"
assert_contains "prompt_hash line"           "prompt_hash: abc123def456"                       "${out6}"
assert_contains "prompt_snapshot_path line"  "prompt_snapshot_path: /tmp/prompts/ab/abc123def456.txt" "${out6}"
assert_contains "prompt_size_bytes line"     "prompt_size_bytes: 2048"                          "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: text rendering surfaces parent / root / spawn_reason"
out7="$(bash "${CAP_SESSION}" inspect sess-tech-002 --sessions-path "${FIXTURE}" 2>&1)"
assert_contains "parent_session_id rendered"  "parent_session_id: sess-prd-001"                 "${out7}"
assert_contains "root_session_id rendered"    "root_session_id: sess-prd-001"                   "${out7}"
assert_contains "spawn_reason rendered"       "spawn_reason: delegate technical planning to specialist" "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: cap session inspect (via cap-entry dispatcher) reaches inspector"
out8="$(bash "${CAP_ENTRY}" session inspect sess-prd-001 --sessions-path "${FIXTURE}" --json 2>&1)"
exit8=$?
assert_eq "cap-entry routing exit 0" "0" "${exit8}"
parsed8="$(printf '%s' "${out8}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('ok=' + str(d['ok']))
print('id=' + d['sessions'][0]['session_id'])
")"
assert_contains "cap-entry json ok"  "ok=True"             "${parsed8}"
assert_contains "cap-entry json id"  "id=sess-prd-001"     "${parsed8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: no positional and no filter → usage error exit 2"
out9="$(bash "${CAP_SESSION}" inspect --sessions-path "${FIXTURE}" 2>&1)"
exit9=$?
# argparse error returns exit 2; accept any non-zero as "rejected"
[ "${exit9}" != "0" ] && echo "  PASS: usage rejected (exit ${exit9})" && pass_count=$((pass_count + 1)) || { echo "  FAIL: usage with no filters should reject; got exit 0"; fail_count=$((fail_count + 1)); }

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "cap-session-inspect: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
