#!/usr/bin/env bash
#
# test-handoff-route-back.sh — P6 #8 gate.
#
# Verifies the CAP_ENFORCE_ROUTE_BACK=1 opt-in path end to end.
# Mirrors the 3-layer split established by P6 #3 / #4:
#
#   Layer 1 — engine/step_runtime.py resolve-handoff-routing CLI:
#     6 verdict branches + 2 operational error branches. Asserts the
#     single-line stdout contract is stable, since cap-workflow-exec.sh
#     parses it via sed.
#
#   Layer 2 — shell branch simulation:
#     re-runs the route_back_to hook against fixture tickets. Pre-jump
#     state (step_idx pointer, VISIT_COUNTS, SHOULD_HALT) is asserted
#     post-resolver. The wrapper-presence check (Layer 3) guards
#     against the production code drifting away from this simulation.
#
#   Layer 3 — wrapper presence check:
#     greps cap-workflow-exec.sh for the env-flag, CLI invocation,
#     STEP_ARRAY mapfile, step_idx pointer, helper functions, and
#     route-history.jsonl emission. Without these the gate silently
#     no-ops even with the flag set.
#
# Cases:
#   1.  CLI ok                      → action=route_back_to;target=prd;reason=ok
#   2.  CLI no_routing (on_fail=halt)→ action=halt;reason=no_routing
#   3.  CLI unsupported retry        → action=halt;reason=unsupported_action
#   4.  CLI missing_target           → action=halt;reason=missing_target
#   5.  CLI invalid_target           → action=halt;reason=invalid_target
#   6.  CLI max_retries_exhausted    → action=halt;reason=max_retries_exhausted
#   7.  CLI missing artifact         → rc 1, reason=missing_artifact
#   8.  CLI parse_error              → rc 1, reason=parse_error
#   9.  shell flag=0 → gate dormant (no resolver call)
#   10. shell flag=1 + valid route   → step_idx jumps + HALT cleared
#   11. shell flag=1 + max retries   → break + history logged
#   12. shell flag=1 + invalid target → break (graceful refusal)
#   13. shell flag=1 + non-ai exec    → gate skipped
#   14. shell flag=1 + no ticket      → gate skipped (no false positive)
#   15. wrapper presence — env flag, CLI call, mapfile, helpers

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
EXEC_SH="${REPO_ROOT}/scripts/cap-workflow-exec.sh"
RESOLVER_PY="${REPO_ROOT}/engine/handoff_route_resolver.py"

[ -f "${STEP_PY}" ] || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }
[ -f "${EXEC_SH}" ] || { echo "FAIL: scripts/cap-workflow-exec.sh missing"; exit 1; }
[ -f "${RESOLVER_PY}" ] || { echo "FAIL: engine/handoff_route_resolver.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-route-back-test.XXXXXX)"
trap 'rm -rf "${SANDBOX}"' EXIT

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
    echo "    expected substring: ${needle}"
    echo "    actual head: $(printf '%s' "${haystack}" | head -3)"
    fail_count=$((fail_count + 1))
  fi
}

# Fixture tickets ────────────────────────────────────────────────────────

HALT_TICKET="${SANDBOX}/halt.ticket.json"
cat > "${HALT_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"halt"}}
EOF

ROUTE_TICKET="${SANDBOX}/route.ticket.json"
cat > "${ROUTE_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"route_back_to","route_back_to_step":"prd","max_retries":2}}
EOF

MISSING_TICKET="${SANDBOX}/missing-target.ticket.json"
cat > "${MISSING_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"route_back_to"}}
EOF

INVALID_TICKET="${SANDBOX}/invalid-target.ticket.json"
cat > "${INVALID_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"route_back_to","route_back_to_step":"nonexistent_step"}}
EOF

RETRY_TICKET="${SANDBOX}/retry.ticket.json"
cat > "${RETRY_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"retry","max_retries":3}}
EOF

ESCALATE_TICKET="${SANDBOX}/escalate.ticket.json"
cat > "${ESCALATE_TICKET}" <<'EOF'
{"failure_routing":{"on_fail":"escalate_user"}}
EOF

PARSE_TICKET="${SANDBOX}/parse.ticket.json"
echo 'not json' > "${PARSE_TICKET}"

PLAN_STEPS="prd,tech_plan,ba,dba_api"

# ── Layer 1: CLI verdict branches ───────────────────────────────────────

echo "Case 1: CLI ok → action=route_back_to;target=prd"
out1="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${ROUTE_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
rc1=$?
assert_eq "rc 0"                            "0"                                  "${rc1}"
assert_contains "action=route_back_to"      "action=route_back_to"               "${out1}"
assert_contains "target resolved"           "target=prd"                         "${out1}"
assert_contains "reason=ok"                 "reason=ok"                          "${out1}"
assert_contains "remaining computed"         "remaining=1"                        "${out1}"

echo "Case 2: CLI on_fail=halt → reason=no_routing"
out2="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${HALT_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
rc2=$?
assert_eq "rc 0"                            "0"                                  "${rc2}"
assert_contains "action=halt"               "action=halt"                        "${out2}"
assert_contains "reason=no_routing"         "reason=no_routing"                  "${out2}"

echo "Case 3: CLI on_fail=retry → reason=unsupported_action"
out3="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${RETRY_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
assert_contains "halt"                      "action=halt"                        "${out3}"
assert_contains "unsupported_action"        "reason=unsupported_action"          "${out3}"

echo "Case 3b: CLI on_fail=escalate_user → reason=unsupported_action"
out3b="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${ESCALATE_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
assert_contains "halt"                      "action=halt"                        "${out3b}"
assert_contains "unsupported_action"        "reason=unsupported_action"          "${out3b}"

echo "Case 4: CLI route_back_to + missing target → reason=missing_target"
out4="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${MISSING_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
assert_contains "halt"                      "action=halt"                        "${out4}"
assert_contains "missing_target"            "reason=missing_target"              "${out4}"

echo "Case 5: CLI route_back_to + target not in plan → reason=invalid_target"
out5="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${INVALID_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
assert_contains "halt"                      "action=halt"                        "${out5}"
assert_contains "invalid_target"            "reason=invalid_target"              "${out5}"

echo "Case 6: CLI route_back_to + visits maxed → reason=max_retries_exhausted"
out6="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${ROUTE_TICKET}" --plan-steps "${PLAN_STEPS}" --visits "prd=2" 2>&1)"
assert_contains "halt"                      "action=halt"                        "${out6}"
assert_contains "max_retries_exhausted"     "reason=max_retries_exhausted"       "${out6}"
assert_contains "target carried"            "target=prd"                         "${out6}"

echo "Case 7: CLI missing artifact → rc 1 reason=missing_artifact"
out7="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${SANDBOX}/no-such.ticket.json" --plan-steps "${PLAN_STEPS}" 2>&1)"
rc7=$?
assert_eq "rc 1 (operational error)"        "1"                                  "${rc7}"
assert_contains "reason=missing_artifact"   "reason=missing_artifact"            "${out7}"

echo "Case 8: CLI parse error → rc 1 reason=parse_error"
out8="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" resolve-handoff-routing "${PARSE_TICKET}" --plan-steps "${PLAN_STEPS}" 2>&1)"
rc8=$?
assert_eq "rc 1 (operational error)"        "1"                                  "${rc8}"
assert_contains "reason=parse_error"        "reason=parse_error"                 "${out8}"

# ── Layer 2: shell branch simulation ────────────────────────────────────
#
# Mirrors the route_back hook block from the central halt point in
# cap-workflow-exec.sh. We synthesize an in-memory STEP_ARRAY with
# placeholder pipe-delimited rows so find_step_idx_in_array's 5th-field
# extraction is exercised.

simulate_route_back() {
  local ticket_path="$1"
  local enforce_flag="$2"
  local effective_executor="${3:-ai}"
  local visits="${4:-}"

  CAP_ENFORCE_ROUTE_BACK="${enforce_flag}" \
  ROUTE_BACK_TICKET_PATH="${ticket_path}" \
  ROUTE_VISITS_ARG="${visits}" \
  ROUTE_BACK_PLAN_STEPS="${PLAN_STEPS}" \
  effective_executor="${effective_executor}" \
  step_id="downstream_step" \
  STEP_PY="${STEP_PY}" \
  PYTHON_BIN="python3" \
  HISTORY_FILE="${SANDBOX}/route-history.jsonl" \
  bash -c '
    set -u
    : > "${HISTORY_FILE}"

    declare -A VISIT_COUNTS
    VISIT_COUNTS["downstream_step"]=1
    if [ -n "${ROUTE_VISITS_ARG}" ]; then
      IFS="," read -ra _kvs <<< "${ROUTE_VISITS_ARG}"
      for kv in "${_kvs[@]}"; do
        IFS="=" read -r k v <<< "${kv}"
        VISIT_COUNTS["${k}"]="${v}"
      done
    fi

    # Build a fake STEP_ARRAY with 4 steps; pipe field 5 = step_id.
    STEP_ARRAY=(
      "1|4|prd|01-Sup|prd|prd_generation|01-Sup|prd.md|claude||False|resolved|600|||summary|planning_artifact||ai|||"
      "2|4|tech_plan|02-TL|tech_plan|technical_planning|02-TL|tp.md|claude||False|resolved|600|||summary|planning_artifact||ai|||"
      "3|4|ba|02a-BA|ba|business_analysis|02a-BA|ba.md|claude||False|resolved|600|||summary|planning_artifact||ai|||"
      "4|4|dba_api|02b-DBA|dba_api|dba_api_design|02b-DBA|dba.md|claude||False|resolved|600|||summary|planning_artifact||ai|||"
    )
    step_idx=4   # we are at the tail; failure occurred on dba_api

    find_step_idx_in_array() {
      local target="$1"
      local i sid
      for i in "${!STEP_ARRAY[@]}"; do
        sid="$(printf "%s" "${STEP_ARRAY[${i}]}" | cut -d"|" -f5)"
        if [ "${sid}" = "${target}" ]; then
          printf "%s" "${i}"
          return 0
        fi
      done
      return 0
    }

    format_visit_counts() {
      local out=""
      local key
      for key in "${!VISIT_COUNTS[@]}"; do
        if [ -z "${out}" ]; then out="${key}=${VISIT_COUNTS[${key}]}"
        else out="${out},${key}=${VISIT_COUNTS[${key}]}"; fi
      done
      printf "%s" "${out}"
    }

    record_route_history() {
      local from="$1" to="$2" reason="$3" action="$4"
      printf "{\"from\":\"%s\",\"to\":\"%s\",\"reason\":\"%s\",\"action\":\"%s\"}\n" \
        "${from}" "${to}" "${reason}" "${action}" >> "${HISTORY_FILE}"
    }

    SHOULD_HALT=1
    ROUTE_TAKEN=0
    ROUTE_REASON_LOGGED=""
    if [ "${CAP_ENFORCE_ROUTE_BACK:-0}" = "1" ] && [ "${effective_executor}" = "ai" ]; then
      if [ -n "${ROUTE_BACK_TICKET_PATH}" ] && [ -f "${ROUTE_BACK_TICKET_PATH}" ]; then
        ROUTE_OUT="$("${PYTHON_BIN}" "${STEP_PY}" resolve-handoff-routing "${ROUTE_BACK_TICKET_PATH}" --plan-steps "${ROUTE_BACK_PLAN_STEPS}" --visits "$(format_visit_counts)" 2>&1)"
        ROUTE_RC=$?
        if [ "${ROUTE_RC}" -eq 0 ]; then
          ROUTE_ACTION="$(printf "%s" "${ROUTE_OUT}" | sed -E "s/^action=([^;]*).*$/\1/")"
          ROUTE_TARGET="$(printf "%s" "${ROUTE_OUT}" | sed -E "s/^.*target=([^;]*);reason=.*$/\1/")"
          ROUTE_REASON="$(printf "%s" "${ROUTE_OUT}" | sed -E "s/^.*reason=([^;]*);remaining=.*$/\1/")"
          if [ "${ROUTE_ACTION}" = "route_back_to" ] && [ -n "${ROUTE_TARGET}" ]; then
            ROUTE_TARGET_IDX="$(find_step_idx_in_array "${ROUTE_TARGET}")"
            if [ -n "${ROUTE_TARGET_IDX}" ]; then
              record_route_history "${step_id}" "${ROUTE_TARGET}" "${ROUTE_REASON}" "route_back_to"
              step_idx="${ROUTE_TARGET_IDX}"
              SHOULD_HALT=0
              ROUTE_TAKEN=1
            fi
          fi
          if [ "${ROUTE_ACTION}" = "halt" ] && [ "${ROUTE_REASON}" != "no_routing" ]; then
            record_route_history "${step_id}" "${ROUTE_TARGET}" "${ROUTE_REASON}" "halt"
            ROUTE_REASON_LOGGED="${ROUTE_REASON}"
          fi
        fi
      fi
    fi
    HISTORY_LINES="$(wc -l < "${HISTORY_FILE}" | tr -d " ")"
    printf "STEP_IDX=%s\nSHOULD_HALT=%s\nROUTE_TAKEN=%s\nREASON_LOGGED=%s\nHISTORY_LINES=%s\n" \
      "${step_idx}" "${SHOULD_HALT}" "${ROUTE_TAKEN}" "${ROUTE_REASON_LOGGED}" "${HISTORY_LINES}"
  '
}

echo "Case 9: shell flag=0 → gate dormant (HALT preserved, no history)"
out9="$(simulate_route_back "${ROUTE_TICKET}" 0)"
assert_contains "STEP_IDX unchanged"        "STEP_IDX=4"          "${out9}"
assert_contains "SHOULD_HALT preserved"     "SHOULD_HALT=1"       "${out9}"
assert_contains "no route taken"            "ROUTE_TAKEN=0"       "${out9}"
assert_contains "no history written"        "HISTORY_LINES=0"     "${out9}"

echo "Case 10: shell flag=1 + valid route → step_idx=0 + HALT cleared + history"
out10="$(simulate_route_back "${ROUTE_TICKET}" 1)"
assert_contains "STEP_IDX rewound"          "STEP_IDX=0"          "${out10}"
assert_contains "SHOULD_HALT cleared"       "SHOULD_HALT=0"       "${out10}"
assert_contains "ROUTE_TAKEN=1"             "ROUTE_TAKEN=1"       "${out10}"
assert_contains "history line written"      "HISTORY_LINES=1"     "${out10}"

echo "Case 11: shell flag=1 + max_retries_exhausted → break + halt history"
out11="$(simulate_route_back "${ROUTE_TICKET}" 1 ai "prd=2")"
assert_contains "STEP_IDX preserved (no jump)" "STEP_IDX=4"       "${out11}"
assert_contains "SHOULD_HALT stays"            "SHOULD_HALT=1"   "${out11}"
assert_contains "no route taken"               "ROUTE_TAKEN=0"   "${out11}"
assert_contains "halt reason logged"           "REASON_LOGGED=max_retries_exhausted" "${out11}"
assert_contains "history line written"         "HISTORY_LINES=1" "${out11}"

echo "Case 12: shell flag=1 + invalid_target → break + halt history"
out12="$(simulate_route_back "${INVALID_TICKET}" 1)"
assert_contains "STEP_IDX preserved"        "STEP_IDX=4"          "${out12}"
assert_contains "SHOULD_HALT stays"         "SHOULD_HALT=1"       "${out12}"
assert_contains "halt reason logged"        "REASON_LOGGED=invalid_target" "${out12}"

echo "Case 13: shell flag=1 + non-ai executor → gate skipped"
out13="$(simulate_route_back "${ROUTE_TICKET}" 1 shell)"
assert_contains "STEP_IDX preserved"        "STEP_IDX=4"          "${out13}"
assert_contains "SHOULD_HALT stays"         "SHOULD_HALT=1"       "${out13}"
assert_contains "no history"                "HISTORY_LINES=0"     "${out13}"

echo "Case 14: shell flag=1 + no ticket → gate skipped"
out14="$(simulate_route_back "${SANDBOX}/no-such.ticket.json" 1)"
assert_contains "STEP_IDX preserved"        "STEP_IDX=4"          "${out14}"
assert_contains "SHOULD_HALT stays"         "SHOULD_HALT=1"       "${out14}"
assert_contains "no history"                "HISTORY_LINES=0"     "${out14}"

# ── Layer 3: wrapper presence guard ─────────────────────────────────────

echo "Case 15: cap-workflow-exec.sh contains route_back wiring"
exec_src="$(cat "${EXEC_SH}")"
assert_contains "env flag check present"        'CAP_ENFORCE_ROUTE_BACK:-0'     "${exec_src}"
assert_contains "resolver CLI call"             'resolve-handoff-routing'       "${exec_src}"
assert_contains "STEP_ARRAY mapfile"             'mapfile -t STEP_ARRAY'         "${exec_src}"
assert_contains "step_idx pointer loop"          'while [ "${step_idx}" -lt'    "${exec_src}"
assert_contains "VISIT_COUNTS associative array" 'declare -A VISIT_COUNTS'      "${exec_src}"
assert_contains "find_step_idx_in_array helper"  'find_step_idx_in_array()'     "${exec_src}"
assert_contains "format_visit_counts helper"     'format_visit_counts()'        "${exec_src}"
assert_contains "record_route_history helper"    'record_route_history()'       "${exec_src}"
assert_contains "ROUTE_HISTORY_FILE emission"    'route-history.jsonl'          "${exec_src}"
assert_contains "ROUTE_BACK_PLAN_STEPS list"     'ROUTE_BACK_PLAN_STEPS'        "${exec_src}"

echo ""
echo "handoff-route-back: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
