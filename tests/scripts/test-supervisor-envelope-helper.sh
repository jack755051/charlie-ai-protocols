#!/usr/bin/env bash
#
# test-supervisor-envelope-helper.sh — Smoke for engine/supervisor_envelope.py
# (P3 #3 producer-side helpers).
#
# What this fixture covers (3 sub-helpers / 18+ assertions):
#
#   Fence extraction:
#     Case 1:  happy path — well-formed fence with valid JSON object payload
#              → ok, payload visible
#     Case 2:  no fence at all → ok=false, error names "missing envelope fence"
#     Case 3:  begin without matching end → ok=false, error names "unbalanced"
#     Case 4:  two pairs of fences → ok=false, error names "unbalanced"
#     Case 5:  end before begin → ok=false, error names "wrong order"
#     Case 6:  empty body between fences → ok=false, error names "empty"
#     Case 7:  malformed JSON inside fence → ok=false, error includes "parse error"
#     Case 8:  top-level array (not object) → ok=false, error names "object"
#
#   JSON-Schema validation pass-through (CLI `validate` subcommand):
#     Case 9:  fully-valid envelope → ok=true, validator=jsonschema
#     Case 10: missing required field (failure_routing) → ok=false, names field
#     Case 11: extract failure short-circuits validate → stage=extract reported
#
#   Drift detection (CLI `drift` subcommand):
#     Case 12: aligned envelope (envelope.task_id == nested) → ok=true
#     Case 13: task_id drift → ok=false, mismatches names "task_id drift"
#     Case 14: source_request drift → ok=false, mismatches names "source_request drift"
#     Case 15: missing task_constitution body → ok=false, mismatches names "task_constitution missing"
#
#   Failure-routing xref (P3 #6, CLI `xref` subcommand):
#     Case 16: clean envelope (default-only, no overrides) → ok=true
#     Case 17: dangling default_route_back_to_step → mismatches names "dangling default"
#     Case 18: dangling overrides[].step_id → mismatches names "dangling overrides[" + step_id
#     Case 19: dangling overrides[].route_back_to_step → mismatches names "route_back_to_step"
#     Case 20: missing failure_routing entirely → mismatches names "failure_routing missing"
#
#   Failure-routing resolve (P3 #6, CLI `resolve` subcommand):
#     Case 21: default-only envelope → all entries source=default, on_fail=halt
#     Case 22: per-step override → matched step source=override with override fields,
#              non-matched stays source=default
#     Case 23: empty overrides=[] → all entries source=default
#     Case 24: extract failure short-circuits resolve → stage=extract surfaced
#
# Determinism: pure helper module, no I/O beyond reading the schema. No
# AI / no network / no installed `cap`. All fixtures are inline strings
# piped via stdin so cross-case state cannot leak.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPER_MODULE="${REPO_ROOT}/engine/supervisor_envelope.py"

[ -f "${HELPER_MODULE}" ] || { echo "FAIL: ${HELPER_MODULE} missing"; exit 1; }

pass_count=0
fail_count=0

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"; pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${desc}"
    echo "    expected to contain: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

# Run a CLI sub-command with stdin input. Returns "STDOUT|STDERR|EXIT".
run_helper() {
  local sub="$1"
  shift
  local stdin="$1"
  shift
  local out err code tmp_out tmp_err
  tmp_out="$(mktemp)"; tmp_err="$(mktemp)"
  set +e
  printf '%s' "${stdin}" \
    | python3 -m engine.supervisor_envelope "${sub}" "$@" \
    >"${tmp_out}" 2>"${tmp_err}"
  code=$?
  set -e
  out="$(cat "${tmp_out}")"; err="$(cat "${tmp_err}")"
  rm -f "${tmp_out}" "${tmp_err}"
  printf '%s|%s|%s' "${out}" "${err}" "${code}"
}

# Fixture: a fully-valid envelope JSON body (newlines preserved through
# the fence so the helpers exercise their multiline parsing).
VALID_BODY='{
  "schema_version": 1,
  "task_id": "smoke-001",
  "source_request": "smoke test envelope helper",
  "produced_at": "2026-05-03T22:00:00Z",
  "supervisor_role": "01-Supervisor",
  "task_constitution": {
    "task_id": "smoke-001",
    "project_id": "smoke-proj",
    "source_request": "smoke test envelope helper",
    "goal": "exercise helper",
    "goal_stage": "informal_planning",
    "success_criteria": ["helper passes its own smoke"],
    "non_goals": [],
    "execution_plan": [{"step_id":"prd","capability":"prd_generation"}]
  },
  "capability_graph": {
    "schema_version": 1,
    "task_id": "smoke-001",
    "goal_stage": "informal_planning",
    "nodes": [{"step_id":"prd","capability":"prd_generation","required":true,"depends_on":[],"reason":"scope"}]
  },
  "governance": {
    "goal_stage": "informal_planning",
    "watcher_mode": "final_only",
    "logger_mode": "milestone_log",
    "context_mode": "summary_first"
  },
  "compile_hints": {},
  "failure_routing": {"default_action":"halt","overrides":[]}
}'

with_fence() {
  printf '<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>\n%s\n<<<SUPERVISOR_ORCHESTRATION_END>>>\n' "$1"
}

# ── Case 1 ──────────────────────────────────────────────────────────────
echo "Case 1: extract — happy path"
result="$(run_helper extract "$(with_fence "${VALID_BODY}")")"
out1="${result%%|*}"; rest="${result#*|}"; exit1="${rest##*|}"
assert_eq "case 1 exit 0" "0" "${exit1}"
assert_contains "case 1 ok=true" '"ok": true' "${out1}"
assert_contains "case 1 payload_present=true" '"payload_present": true' "${out1}"

# ── Case 2 ──────────────────────────────────────────────────────────────
echo "Case 2: extract — no fence"
result="$(run_helper extract "this response has no fence at all")"
out2="${result%%|*}"; rest="${result#*|}"; exit2="${rest##*|}"
assert_eq "case 2 exit 1" "1" "${exit2}"
assert_contains "case 2 names missing fence" "missing envelope fence" "${out2}"

# ── Case 3 ──────────────────────────────────────────────────────────────
echo "Case 3: extract — begin without end"
result="$(run_helper extract '<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{}')"
out3="${result%%|*}"; rest="${result#*|}"; exit3="${rest##*|}"
assert_eq "case 3 exit 1" "1" "${exit3}"
assert_contains "case 3 names unbalanced" "unbalanced" "${out3}"

# ── Case 4 ──────────────────────────────────────────────────────────────
echo "Case 4: extract — two pairs of fences"
# Bash $() command substitution strips trailing newlines, which would
# concatenate END+BEGIN on the same line and silently bypass the
# multiline regex. Use an inline literal so two distinct fence pairs
# survive verbatim.
double_input='<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{"a": 1}
<<<SUPERVISOR_ORCHESTRATION_END>>>

<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{"b": 2}
<<<SUPERVISOR_ORCHESTRATION_END>>>'
result="$(run_helper extract "${double_input}")"
out4="${result%%|*}"; rest="${result#*|}"; exit4="${rest##*|}"
assert_eq "case 4 exit 1" "1" "${exit4}"
assert_contains "case 4 names unbalanced" "unbalanced" "${out4}"

# ── Case 5 ──────────────────────────────────────────────────────────────
echo "Case 5: extract — end before begin"
result="$(run_helper extract '<<<SUPERVISOR_ORCHESTRATION_END>>>
{}
<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>')"
out5="${result%%|*}"; rest="${result#*|}"; exit5="${rest##*|}"
assert_eq "case 5 exit 1" "1" "${exit5}"
assert_contains "case 5 names wrong order" "wrong order" "${out5}"

# ── Case 6 ──────────────────────────────────────────────────────────────
echo "Case 6: extract — empty body between fences"
result="$(run_helper extract '<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>

<<<SUPERVISOR_ORCHESTRATION_END>>>')"
out6="${result%%|*}"; rest="${result#*|}"; exit6="${rest##*|}"
assert_eq "case 6 exit 1" "1" "${exit6}"
assert_contains "case 6 names empty body" "empty" "${out6}"

# ── Case 7 ──────────────────────────────────────────────────────────────
echo "Case 7: extract — malformed JSON inside fence"
result="$(run_helper extract '<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
{not: valid json}
<<<SUPERVISOR_ORCHESTRATION_END>>>')"
out7="${result%%|*}"; rest="${result#*|}"; exit7="${rest##*|}"
assert_eq "case 7 exit 1" "1" "${exit7}"
assert_contains "case 7 names parse error" "parse error" "${out7}"

# ── Case 8 ──────────────────────────────────────────────────────────────
echo "Case 8: extract — top-level array (not object)"
result="$(run_helper extract '<<<SUPERVISOR_ORCHESTRATION_BEGIN>>>
[1, 2, 3]
<<<SUPERVISOR_ORCHESTRATION_END>>>')"
out8="${result%%|*}"; rest="${result#*|}"; exit8="${rest##*|}"
assert_eq "case 8 exit 1" "1" "${exit8}"
assert_contains "case 8 names object requirement" "object at the top level" "${out8}"

# ── Case 9 ──────────────────────────────────────────────────────────────
echo "Case 9: validate — fully-valid envelope"
result="$(run_helper validate "$(with_fence "${VALID_BODY}")")"
out9="${result%%|*}"; rest="${result#*|}"; exit9="${rest##*|}"
assert_eq "case 9 exit 0" "0" "${exit9}"
assert_contains "case 9 stage=validate" '"stage": "validate"' "${out9}"
assert_contains "case 9 ok=true" '"ok": true' "${out9}"
assert_contains "case 9 validator=jsonschema" '"validator": "jsonschema"' "${out9}"

# ── Case 10 ─────────────────────────────────────────────────────────────
echo "Case 10: validate — missing failure_routing required"
broken_body="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
del d["failure_routing"]
print(json.dumps(d))
')"
result="$(run_helper validate "$(with_fence "${broken_body}")")"
out10="${result%%|*}"; rest="${result#*|}"; exit10="${rest##*|}"
assert_eq "case 10 exit 1" "1" "${exit10}"
assert_contains "case 10 stage=validate" '"stage": "validate"' "${out10}"
assert_contains "case 10 names failure_routing" "failure_routing" "${out10}"

# ── Case 11 ─────────────────────────────────────────────────────────────
echo "Case 11: validate — short-circuits when extract fails"
result="$(run_helper validate "no fence here at all")"
out11="${result%%|*}"; rest="${result#*|}"; exit11="${rest##*|}"
assert_eq "case 11 exit 1" "1" "${exit11}"
# When extraction fails, validate must report the extract stage error
# instead of running schema validation on nothing.
assert_contains "case 11 stage=extract" '"stage": "extract"' "${out11}"

# ── Case 12 ─────────────────────────────────────────────────────────────
echo "Case 12: drift — aligned envelope"
result="$(run_helper drift "$(with_fence "${VALID_BODY}")")"
out12="${result%%|*}"; rest="${result#*|}"; exit12="${rest##*|}"
assert_eq "case 12 exit 0" "0" "${exit12}"
assert_contains "case 12 stage=drift" '"stage": "drift"' "${out12}"
assert_contains "case 12 ok=true" '"ok": true' "${out12}"

# ── Case 13 ─────────────────────────────────────────────────────────────
echo "Case 13: drift — task_id mismatch between envelope and nested"
drift_body="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["task_id"] = "envelope-says-X"
d["task_constitution"]["task_id"] = "nested-says-Y"
print(json.dumps(d))
')"
result="$(run_helper drift "$(with_fence "${drift_body}")")"
out13="${result%%|*}"; rest="${result#*|}"; exit13="${rest##*|}"
assert_eq "case 13 exit 1" "1" "${exit13}"
assert_contains "case 13 names task_id drift" "task_id drift" "${out13}"

# ── Case 14 ─────────────────────────────────────────────────────────────
echo "Case 14: drift — source_request mismatch"
src_drift="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["source_request"] = "envelope says A"
d["task_constitution"]["source_request"] = "nested says B"
print(json.dumps(d))
')"
result="$(run_helper drift "$(with_fence "${src_drift}")")"
out14="${result%%|*}"; rest="${result#*|}"; exit14="${rest##*|}"
assert_eq "case 14 exit 1" "1" "${exit14}"
assert_contains "case 14 names source_request drift" "source_request drift" "${out14}"

# ── Case 15 ─────────────────────────────────────────────────────────────
echo "Case 15: drift — missing task_constitution body"
no_tc="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
del d["task_constitution"]
print(json.dumps(d))
')"
result="$(run_helper drift "$(with_fence "${no_tc}")")"
out15="${result%%|*}"; rest="${result#*|}"; exit15="${rest##*|}"
assert_eq "case 15 exit 1" "1" "${exit15}"
assert_contains "case 15 names missing task_constitution" "task_constitution missing" "${out15}"

# ── Case 16 ─────────────────────────────────────────────────────────────
# P3 #6 xref helper: aligned envelope (default halt, no overrides) → ok.
# Reuse VALID_BODY whose capability_graph has node step_id="prd" and a
# default_action=halt with overrides=[].
echo "Case 16: xref — clean default-only envelope"
result="$(run_helper xref "$(with_fence "${VALID_BODY}")")"
out16="${result%%|*}"; rest="${result#*|}"; exit16="${rest##*|}"
assert_eq "case 16 exit 0" "0" "${exit16}"
assert_contains "case 16 stage=xref" '"stage": "xref"' "${out16}"
assert_contains "case 16 ok=true" '"ok": true' "${out16}"

# ── Case 17 ─────────────────────────────────────────────────────────────
echo "Case 17: xref — dangling default_route_back_to_step"
dangling_default="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["failure_routing"] = {
    "default_action": "route_back_to",
    "default_route_back_to_step": "no-such-step",
    "overrides": [],
}
print(json.dumps(d))
')"
result="$(run_helper xref "$(with_fence "${dangling_default}")")"
out17="${result%%|*}"; rest="${result#*|}"; exit17="${rest##*|}"
assert_eq "case 17 exit 1" "1" "${exit17}"
assert_contains "case 17 ok=false" '"ok": false' "${out17}"
assert_contains "case 17 names dangling default" \
  "dangling default_route_back_to_step" "${out17}"

# ── Case 18 ─────────────────────────────────────────────────────────────
echo "Case 18: xref — dangling overrides[].step_id"
dangling_step="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["failure_routing"] = {
    "default_action": "halt",
    "overrides": [{"step_id": "phantom-step", "on_fail": "halt"}],
}
print(json.dumps(d))
')"
result="$(run_helper xref "$(with_fence "${dangling_step}")")"
out18="${result%%|*}"; rest="${result#*|}"; exit18="${rest##*|}"
assert_eq "case 18 exit 1" "1" "${exit18}"
assert_contains "case 18 names dangling overrides step_id" \
  "dangling overrides[" "${out18}"
assert_contains "case 18 surfaces phantom step name" "phantom-step" "${out18}"

# ── Case 19 ─────────────────────────────────────────────────────────────
echo "Case 19: xref — dangling overrides[].route_back_to_step"
dangling_back="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["failure_routing"] = {
    "default_action": "halt",
    "overrides": [{
        "step_id": "prd",
        "on_fail": "route_back_to",
        "route_back_to_step": "phantom-target",
    }],
}
print(json.dumps(d))
')"
result="$(run_helper xref "$(with_fence "${dangling_back}")")"
out19="${result%%|*}"; rest="${result#*|}"; exit19="${rest##*|}"
assert_eq "case 19 exit 1" "1" "${exit19}"
assert_contains "case 19 names route_back_to_step" \
  "route_back_to_step" "${out19}"
assert_contains "case 19 surfaces phantom target" "phantom-target" "${out19}"

# ── Case 20 ─────────────────────────────────────────────────────────────
echo "Case 20: xref — missing failure_routing block"
no_routing="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
del d["failure_routing"]
print(json.dumps(d))
')"
result="$(run_helper xref "$(with_fence "${no_routing}")")"
out20="${result%%|*}"; rest="${result#*|}"; exit20="${rest##*|}"
assert_eq "case 20 exit 1" "1" "${exit20}"
assert_contains "case 20 names failure_routing missing" \
  "failure_routing missing" "${out20}"

# ── Case 21 ─────────────────────────────────────────────────────────────
echo "Case 21: resolve — default-only → all entries source=default, on_fail=halt"
result="$(run_helper resolve "$(with_fence "${VALID_BODY}")")"
out21="${result%%|*}"; rest="${result#*|}"; exit21="${rest##*|}"
assert_eq "case 21 exit 0" "0" "${exit21}"
assert_contains "case 21 stage=resolve" '"stage": "resolve"' "${out21}"
assert_contains "case 21 first entry step_id=prd" '"step_id": "prd"' "${out21}"
assert_contains "case 21 source=default" '"source": "default"' "${out21}"
assert_contains "case 21 on_fail=halt" '"on_fail": "halt"' "${out21}"

# ── Case 22 ─────────────────────────────────────────────────────────────
# Two-step graph + per-step override: matched step gets source=override
# with override fields; non-matched stays source=default.
echo "Case 22: resolve — per-step override"
two_step="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["task_constitution"]["execution_plan"] = [
    {"step_id":"prd","capability":"prd_generation"},
    {"step_id":"tech","capability":"technical_planning"},
]
d["capability_graph"]["nodes"] = [
    {"step_id":"prd","capability":"prd_generation","required":True,"depends_on":[],"reason":""},
    {"step_id":"tech","capability":"technical_planning","required":True,"depends_on":["prd"],"reason":""},
]
d["failure_routing"] = {
    "default_action": "halt",
    "overrides": [{"step_id":"tech","on_fail":"retry","max_retries":2}],
}
print(json.dumps(d))
')"
result="$(run_helper resolve "$(with_fence "${two_step}")")"
out22="${result%%|*}"; rest="${result#*|}"; exit22="${rest##*|}"
assert_eq "case 22 exit 0" "0" "${exit22}"
# Validate full ordered structure via Python so positional alignment is
# verified, not just substring presence.
ordered_check="$(printf '%s' "${out22}" \
  | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
r = data.get("resolved", [])
ok = (
    len(r) == 2
    and r[0]["step_id"] == "prd"  and r[0]["source"] == "default"  and r[0]["on_fail"] == "halt"
    and r[1]["step_id"] == "tech" and r[1]["source"] == "override" and r[1]["on_fail"] == "retry" and r[1]["max_retries"] == 2
)
print("aligned" if ok else "misaligned")
')"
assert_eq "case 22 resolved order + per-step override" "aligned" "${ordered_check}"

# ── Case 23 ─────────────────────────────────────────────────────────────
echo "Case 23: resolve — empty overrides=[] → all entries source=default"
empty_ov="$(printf '%s' "${VALID_BODY}" \
  | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
d["failure_routing"] = {"default_action": "halt", "overrides": []}
print(json.dumps(d))
')"
result="$(run_helper resolve "$(with_fence "${empty_ov}")")"
out23="${result%%|*}"; rest="${result#*|}"; exit23="${rest##*|}"
assert_eq "case 23 exit 0" "0" "${exit23}"
assert_contains "case 23 source=default" '"source": "default"' "${out23}"
# Make sure no stray override accidentally surfaces.
if printf '%s' "${out23}" | grep -qE '"source":[[:space:]]*"override"'; then
  echo "  FAIL: case 23 unexpected override entry"; fail_count=$((fail_count + 1))
else
  echo "  PASS: case 23 no override entries"; pass_count=$((pass_count + 1))
fi

# ── Case 24 ─────────────────────────────────────────────────────────────
echo "Case 24: resolve — extract failure short-circuits"
result="$(run_helper resolve "no fence here")"
out24="${result%%|*}"; rest="${result#*|}"; exit24="${rest##*|}"
assert_eq "case 24 exit 1" "1" "${exit24}"
assert_contains "case 24 stage=extract surfaced" '"stage": "extract"' "${out24}"

# ── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------------------------"
echo "Summary: ${pass_count} passed, ${fail_count} failed"
echo "----------------------------------------------------------------"

[ ${fail_count} -eq 0 ]
