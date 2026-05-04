#!/usr/bin/env bash
#
# test-cap-session-analyze.sh — gate for `cap session analyze` token /
# time analytics CLI (engine/session_cost_analyzer.py + cap-session.sh
# `analyze` dispatcher).
#
# Coverage (hermetic — uses --sessions-path to pin a fixture file):
#   Case 1 text mode aggregates:    total / duration / lifecycle /
#                                   by_provider / by_capability /
#                                   largest_prompts / duplicate_prompts /
#                                   longest_sessions / failures sections
#                                   all rendered.
#   Case 2 JSON mode envelope:      --json returns parseable
#                                   {ok: true, total_sessions, ...}.
#   Case 3 duplicate detection:     hash repeated 2x is surfaced in
#                                   duplicate_prompts.
#   Case 4 largest prompts order:   sorted desc by prompt_size_bytes.
#   Case 5 longest sessions order:  sorted desc by duration_seconds.
#   Case 6 timeout vs other fail:   failure_reason starting with
#                                   'timeout:' counted in failures.timeout
#                                   sub-bucket; non-timeout failure not
#                                   counted there.
#   Case 7 by_capability failures:  failed sessions grouped by capability.
#   Case 8 --top truncation:        top N respected on hot lists.
#   Case 9 --run-id filter:         narrows to one run; analytics
#                                   recomputed over the subset.
#   Case 10 missing → exit 1:       empty fixture → deterministic JSON
#                                   error {"ok": false,
#                                   "error": "no_sessions_found", ...}.
#   Case 11 cap-entry routing:      cap session analyze (via
#                                   cap-entry.sh → cap-session.sh
#                                   dispatcher) reaches the analyzer.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

[ -f "${REPO_ROOT}/engine/session_cost_analyzer.py" ] || {
  echo "FAIL: engine/session_cost_analyzer.py missing"; exit 1;
}
[ -f "${REPO_ROOT}/scripts/cap-session.sh" ] || {
  echo "FAIL: scripts/cap-session.sh missing"; exit 1;
}

SANDBOX="$(mktemp -d -t cap-sess-analyze-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

FIXTURE="${SANDBOX}/agent-sessions.json"
cat > "${FIXTURE}" <<'EOF'
{
  "run_id": "run-A",
  "workflow_id": "wf-spec",
  "workflow_name": "Spec Pipeline",
  "sessions": [
    {"session_id":"sA","run_id":"run-A","workflow_id":"wf-spec","step_id":"prd",
     "capability":"prd_generation","lifecycle":"completed","result":"passed",
     "provider":"claude","provider_cli":"claude","executor":"ai","duration_seconds":12,
     "prompt_hash":"hash-X","prompt_size_bytes":2048,"failure_reason":null},
    {"session_id":"sB","run_id":"run-A","workflow_id":"wf-spec","step_id":"tech",
     "capability":"tech_planning","lifecycle":"failed","result":"failed",
     "provider":"codex","provider_cli":"codex","executor":"ai","duration_seconds":30,
     "prompt_hash":"hash-Y","prompt_size_bytes":4096,
     "failure_reason":"timeout: codex command exceeded 30s"},
    {"session_id":"sC","run_id":"run-A","workflow_id":"wf-spec","step_id":"prd-retry",
     "capability":"prd_generation","lifecycle":"completed","result":"passed",
     "provider":"claude","provider_cli":"claude","executor":"ai","duration_seconds":18,
     "prompt_hash":"hash-X","prompt_size_bytes":2048,"failure_reason":null},
    {"session_id":"sD","run_id":"run-A","workflow_id":"wf-spec","step_id":"shell-op",
     "capability":"shell_op","lifecycle":"completed","result":"passed",
     "provider":"shell","provider_cli":"shell","executor":"shell","duration_seconds":1,
     "prompt_hash":"hash-Z","prompt_size_bytes":256,"failure_reason":null},
    {"session_id":"sE","run_id":"run-B","workflow_id":"wf-impl","step_id":"backend",
     "capability":"backend_dev","lifecycle":"failed","result":"failed",
     "provider":"claude","provider_cli":"claude","executor":"ai","duration_seconds":3,
     "prompt_hash":"hash-W","prompt_size_bytes":512,"failure_reason":"claude exited 5"}
  ]
}
EOF

EMPTY_FIXTURE="${SANDBOX}/empty.json"
echo '{"sessions":[]}' > "${EMPTY_FIXTURE}"

CAP_SESSION="${REPO_ROOT}/scripts/cap-session.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

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

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: text-mode rendering covers all sections"
out1="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" 2>&1)"
exit1=$?
assert_eq        "exit 0 happy path"          "0"                            "${exit1}"
assert_contains "total_sessions header"      "total_sessions: 5"             "${out1}"
assert_contains "total_duration_seconds"     "total_duration_seconds: 64"    "${out1}"
assert_contains "lifecycle section"           "lifecycle:"                    "${out1}"
assert_contains "by_provider section"         "by_provider"                   "${out1}"
assert_contains "by_capability section"       "by_capability"                 "${out1}"
assert_contains "largest_prompts section"     "largest_prompts"               "${out1}"
assert_contains "duplicate_prompts section"   "duplicate_prompts"             "${out1}"
assert_contains "longest_sessions section"    "longest_sessions"              "${out1}"
assert_contains "failures section"            "failures:"                     "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: JSON envelope parseable"
out2="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1)"
exit2=$?
parsed="$(printf '%s' "${out2}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['ok'] is True
print('total=' + str(d['total_sessions']))
print('duration=' + str(d['total_duration_seconds']))
print('failures_total=' + str(d['failures']['total']))
print('failures_timeout=' + str(d['failures']['timeout']))
print('lifecycles=' + ','.join(sorted(d['lifecycle_counts'].keys())))
")"
assert_eq        "exit 0 json mode"          "0"                          "${exit2}"
assert_contains "total counted"               "total=5"                   "${parsed}"
assert_contains "duration aggregated"         "duration=64"               "${parsed}"
assert_contains "failures total"              "failures_total=2"          "${parsed}"
assert_contains "failures timeout subset"     "failures_timeout=1"        "${parsed}"
assert_contains "lifecycle keys present"      "lifecycles=completed,failed" "${parsed}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: duplicate prompt hash surfaced"
out3="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1)"
parsed3="$(printf '%s' "${out3}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
dups = d['duplicate_prompts']
print('count=' + str(len(dups)))
if dups:
    print('hash=' + dups[0]['prompt_hash'])
    print('occurrences=' + str(dups[0]['occurrences']))
")"
assert_contains "one duplicate group found" "count=1"          "${parsed3}"
assert_contains "duplicate is hash-X"        "hash=hash-X"     "${parsed3}"
assert_contains "occurred twice"             "occurrences=2"   "${parsed3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: largest_prompts ordered by size desc"
parsed4="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
lp = d['largest_prompts']
print('top_size=' + str(lp[0]['prompt_size_bytes']))
print('top_session=' + lp[0]['session_id'])
print('order=' + ','.join(str(p['prompt_size_bytes']) for p in lp))
")"
assert_contains "largest is 4096B"      "top_size=4096"        "${parsed4}"
assert_contains "largest is sB (tech)"   "top_session=sB"      "${parsed4}"
assert_contains "size order desc"        "order=4096,2048,2048,512,256" "${parsed4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: longest_sessions ordered by duration desc"
parsed5="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
ls = d['longest_sessions']
print('top_duration=' + str(ls[0]['duration_seconds']))
print('top_id=' + ls[0]['session_id'])
print('order=' + ','.join(str(s['duration_seconds']) for s in ls))
")"
assert_contains "longest is 30s (sB)"  "top_duration=30"     "${parsed5}"
assert_contains "id is sB"              "top_id=sB"          "${parsed5}"
assert_contains "duration order desc"   "order=30,18,12,3,1" "${parsed5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: timeout failures isolated from non-timeout failures"
parsed6="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('total=' + str(d['failures']['total']))
print('timeout=' + str(d['failures']['timeout']))
print('non_timeout=' + str(d['failures']['total'] - d['failures']['timeout']))
")"
assert_contains "two total failures"     "total=2"        "${parsed6}"
assert_contains "one timeout failure"    "timeout=1"      "${parsed6}"
assert_contains "one non-timeout fail"   "non_timeout=1"  "${parsed6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: failures grouped by capability"
parsed7="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
fbc = d['failures']['by_capability']
print('keys=' + ','.join(sorted(fbc.keys())))
print('tech_planning_count=' + str(fbc.get('tech_planning', 0)))
print('backend_dev_count=' + str(fbc.get('backend_dev', 0)))
")"
assert_contains "two failure capabilities" "keys=backend_dev,tech_planning" "${parsed7}"
assert_contains "tech_planning count 1"     "tech_planning_count=1"          "${parsed7}"
assert_contains "backend_dev count 1"       "backend_dev_count=1"            "${parsed7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: --top truncates hot lists"
parsed8="$(bash "${CAP_SESSION}" analyze --sessions-path "${FIXTURE}" --top 2 --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('largest_n=' + str(len(d['largest_prompts'])))
print('longest_n=' + str(len(d['longest_sessions'])))
")"
assert_contains "largest truncated to 2" "largest_n=2" "${parsed8}"
assert_contains "longest truncated to 2"  "longest_n=2" "${parsed8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: --run-id filter narrows analytics"
parsed9="$(bash "${CAP_SESSION}" analyze --run-id run-B --sessions-path "${FIXTURE}" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('total=' + str(d['total_sessions']))
print('duration=' + str(d['total_duration_seconds']))
print('only_id=' + d['longest_sessions'][0]['session_id'])
print('failures_total=' + str(d['failures']['total']))
")"
assert_contains "filter keeps 1 session"     "total=1"           "${parsed9}"
assert_contains "filtered duration"           "duration=3"       "${parsed9}"
assert_contains "filtered session is sE"      "only_id=sE"       "${parsed9}"
assert_contains "filter recounted failures"   "failures_total=1" "${parsed9}"

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: empty fixture → exit 1 with deterministic JSON error"
out10="$(bash "${CAP_SESSION}" analyze --sessions-path "${EMPTY_FIXTURE}" 2>&1)"
exit10=$?
assert_eq        "exit 1 on empty"               "1"                                       "${exit10}"
assert_contains "deterministic error tag"        "\"error\": \"no_sessions_found\""        "${out10}"
assert_contains "query echoed back"               "\"sessions_path\": \"${EMPTY_FIXTURE}\"" "${out10}"

# ── Case 11 ─────────────────────────────────────────────────────────────
echo "Case 11: cap session analyze (via cap-entry dispatcher) reaches analyzer"
out11="$(bash "${CAP_ENTRY}" session analyze --sessions-path "${FIXTURE}" --json 2>&1)"
exit11=$?
assert_eq "cap-entry routing exit 0" "0" "${exit11}"
parsed11="$(printf '%s' "${out11}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('ok=' + str(d['ok']))
print('total=' + str(d['total_sessions']))
")"
assert_contains "cap-entry json ok"   "ok=True"  "${parsed11}"
assert_contains "cap-entry total=5"   "total=5"  "${parsed11}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "cap-session-analyze: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
