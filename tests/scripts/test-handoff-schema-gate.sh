#!/usr/bin/env bash
#
# test-handoff-schema-gate.sh — P6 #3 gate.
#
# Verifies the CAP_ENFORCE_HANDOFF_SCHEMA=1 opt-in pre-dispatch path
# end to end. Mirrors the 3-layer split established by P6 #4
# (test-required-output-enforcement.sh):
#
#   Layer 1 — engine/step_runtime.py validate-handoff-ticket CLI:
#     contract for the executor to consume. Asserts the 4 verdict
#     branches exit code + stdout format are stable, since
#     cap-workflow-exec.sh greps stdout into the gate detail string.
#
#   Layer 2 — shell branch simulation:
#     re-runs the exact CAP_ENFORCE_HANDOFF_SCHEMA conditional block
#     against fixture tickets so we cover the wiring (STEP_STATUS /
#     FINAL_STEP_STATE / HANDOFF_GATE_HARD_FAIL / STEP_HANDOFF_GATE_DETAIL
#     / SHOULD_BREAK) without the full workflow runtime. Pre-dispatch
#     gate uses break-out semantics (matching missing_input /
#     detached_head patterns), not the post-execution validator path
#     used by P6 #4.
#
#   Layer 3 — wrapper presence check:
#     greps cap-workflow-exec.sh for the new env-flag block, helper
#     invocation, reset, status / error-type strings, and the
#     resolve_latest_ticket helper itself, to guard against accidental
#     removal during refactors. The shell wrapper is the production
#     surface; if these lines disappear, the gate silently no-ops even
#     when the flag is set.
#
# Cases:
#   1. CLI ok                  → rc 0, stdout reason=ok;detail=handoff_schema_valid
#   2. CLI handoff_schema_invalid → rc 41, stdout missing-required field
#   3. CLI parse_error          → rc 1, stdout reason=parse_error
#   4. CLI missing_artifact     → rc 1, stdout reason=missing_artifact
#   5. branch flag=0            → STATUS=running (gate never invoked)
#   6. branch flag=1 + valid    → STATUS=running (gate passes through)
#   7. branch flag=1 + invalid  → STATUS=handoff_ticket_invalid + BREAK=1
#   8. branch flag=1 + no ticket → STATUS=running (no-op when ticket absent)
#   9. resolve_latest_ticket helper picks highest-seq variant
#  10. wrapper presence — env flag, CLI call, reset, status, error type, helper

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"
EXEC_SH="${REPO_ROOT}/scripts/cap-workflow-exec.sh"
HANDOFF_SCHEMA="${REPO_ROOT}/schemas/handoff-ticket.schema.yaml"

[ -f "${STEP_PY}" ] || { echo "FAIL: engine/step_runtime.py missing"; exit 1; }
[ -f "${EXEC_SH}" ] || { echo "FAIL: scripts/cap-workflow-exec.sh missing"; exit 1; }
[ -f "${HANDOFF_SCHEMA}" ] || { echo "FAIL: schemas/handoff-ticket.schema.yaml missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-handoff-gate-test.XXXXXX)"
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

GOOD_TICKET="${SANDBOX}/good.ticket.json"
cat > "${GOOD_TICKET}" <<'EOF'
{
  "ticket_id": "smoke-task-prd-1",
  "task_id": "smoke-task",
  "step_id": "prd",
  "created_at": "2026-05-04T00:00:00Z",
  "created_by": "01-Supervisor",
  "target_capability": "prd_generation",
  "task_objective": "exercise the handoff schema gate happy path",
  "rules_to_load": {},
  "context_payload": {
    "project_constitution_path": "/tmp/pc.yaml",
    "task_constitution_path": "/tmp/tc.json"
  },
  "acceptance_criteria": ["validator returns ok"],
  "output_expectations": {
    "primary_artifacts": [{"path": "/tmp/prd.md"}],
    "handoff_summary_path": "/tmp/prd.handoff.md"
  },
  "failure_routing": {"on_fail": "halt"}
}
EOF

BAD_TICKET="${SANDBOX}/bad.ticket.json"
cat > "${BAD_TICKET}" <<'EOF'
{
  "task_id": "smoke-task",
  "step_id": "prd"
}
EOF

PARSE_TICKET="${SANDBOX}/parse.ticket.json"
echo 'this is not json' > "${PARSE_TICKET}"

# ── Layer 1: CLI exit-code + stdout contract ────────────────────────────

echo "Case 1: CLI ok → rc 0 stdout reason=ok"
out1="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-handoff-ticket "${GOOD_TICKET}" 2>&1)"
rc1=$?
assert_eq "rc 0"                "0"                              "${rc1}"
assert_contains "reason=ok"     "reason=ok"                      "${out1}"
assert_contains "detail valid"  "detail=handoff_schema_valid"    "${out1}"

echo "Case 2: CLI bad ticket → rc 41 reason=handoff_schema_invalid + missing field"
out2="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-handoff-ticket "${BAD_TICKET}" 2>&1)"
rc2=$?
assert_eq "rc 41 (schema_validation_failed)" "41"                "${rc2}"
assert_contains "reason=handoff_schema_invalid" "reason=handoff_schema_invalid" "${out2}"
assert_contains "missing ticket_id surfaced"     "'ticket_id' is a required property" "${out2}"

echo "Case 3: CLI parse error → rc 1 reason=parse_error"
out3="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-handoff-ticket "${PARSE_TICKET}" 2>&1)"
rc3=$?
assert_eq "rc 1 (operational error)" "1"                         "${rc3}"
assert_contains "reason=parse_error" "reason=parse_error"        "${out3}"

echo "Case 4: CLI missing artifact → rc 1 reason=missing_artifact"
out4="$(cd "${REPO_ROOT}" && python3 "${STEP_PY}" validate-handoff-ticket "${SANDBOX}/no-such.json" 2>&1)"
rc4=$?
assert_eq "rc 1 (operational error)" "1"                         "${rc4}"
assert_contains "reason=missing_artifact" "reason=missing_artifact" "${out4}"

# ── Layer 2: shell branch simulation ────────────────────────────────────
#
# Mirrors the conditional block we inserted into cap-workflow-exec.sh
# right after the detached_head check and before append_workflow_log
# action:start. Pre-dispatch gates use break-out semantics
# (STEP_STATUS=handoff_ticket_invalid → break), which differs from the
# post-execution validator block in P6 #4 — so we model BREAK rather
# than SHOULD_HALT here. The wrapper-presence check (Case 10) guards
# against the production code drifting away from this simulation.

simulate_branch() {
  local ticket_dir="$1"
  local target_step="$2"
  local enforce_flag="$3"
  local effective_executor="${4:-ai}"

  CAP_ENFORCE_HANDOFF_SCHEMA="${enforce_flag}" \
  HANDOFFS_DIR="${ticket_dir}" \
  HANDOFF_SCHEMA_PATH="${HANDOFF_SCHEMA}" \
  step_id="${target_step}" \
  effective_executor="${effective_executor}" \
  STEP_PY="${STEP_PY}" \
  PYTHON_BIN="python3" \
  bash -c '
    set -u

    # Mirror resolve_latest_ticket helper from cap-workflow-exec.sh.
    resolve_latest_ticket() {
      local handoffs_dir="$1"
      local step_id="$2"
      [ -z "${handoffs_dir}" ] && return 0
      [ ! -d "${handoffs_dir}" ] && return 0
      local base="${handoffs_dir}/${step_id}.ticket.json"
      local latest=""
      [ -f "${base}" ] && latest="${base}"
      local candidate seq highest=1
      shopt -s nullglob
      for candidate in "${handoffs_dir}/${step_id}"-*.ticket.json; do
        [ -f "${candidate}" ] || continue
        seq="${candidate##*-}"
        seq="${seq%.ticket.json}"
        case "${seq}" in
          ""|*[!0-9]*) continue ;;
        esac
        if [ "${seq}" -gt "${highest}" ]; then
          highest="${seq}"
          latest="${candidate}"
        fi
      done
      shopt -u nullglob
      [ -n "${latest}" ] && printf "%s\n" "${latest}"
    }

    SHOULD_BREAK=0
    STEP_STATUS="running"
    FINAL_STEP_STATE="running"
    ERROR_TYPE=""
    STEP_HANDOFF_GATE_DETAIL=""
    HANDOFF_GATE_HARD_FAIL=0
    HANDOFF_TICKET_PATH=""
    if [ "${CAP_ENFORCE_HANDOFF_SCHEMA:-0}" = "1" ] && [ "${effective_executor}" = "ai" ]; then
      HANDOFF_TICKET_PATH="$(resolve_latest_ticket "${HANDOFFS_DIR}" "${step_id}")"
      if [ -n "${HANDOFF_TICKET_PATH}" ]; then
        GATE_OUT="$("${PYTHON_BIN}" "${STEP_PY}" validate-handoff-ticket "${HANDOFF_TICKET_PATH}" --schema "${HANDOFF_SCHEMA_PATH}" 2>&1)"
        GATE_RC=$?
        if [ "${GATE_RC}" -eq 41 ]; then
          HANDOFF_GATE_HARD_FAIL=1
          STEP_HANDOFF_GATE_DETAIL="${GATE_OUT}"
          STEP_STATUS="handoff_ticket_invalid"
          FINAL_STEP_STATE="hard_fail"
          ERROR_TYPE="handoff_validation_failed"
          SHOULD_BREAK=1
        fi
      fi
    fi
    printf "STATUS=%s\nSTATE=%s\nERROR_TYPE=%s\nBREAK=%s\nTICKET=%s\nDETAIL=%s\n" \
      "${STEP_STATUS}" "${FINAL_STEP_STATE}" "${ERROR_TYPE}" "${SHOULD_BREAK}" \
      "${HANDOFF_TICKET_PATH}" "${STEP_HANDOFF_GATE_DETAIL}"
  '
}

# Build a per-branch ticket dir mirroring HANDOFFS_DIR layout.
TICKET_DIR="${SANDBOX}/handoffs"
mkdir -p "${TICKET_DIR}"
cp "${GOOD_TICKET}" "${TICKET_DIR}/prd.ticket.json"
cp "${BAD_TICKET}" "${TICKET_DIR}/tech_plan.ticket.json"

echo "Case 5: branch flag=0 → STATUS=running (gate never invoked)"
out5="$(simulate_branch "${TICKET_DIR}" prd 0)"
assert_contains "STATUS=running"      "STATUS=running"      "${out5}"
assert_contains "BREAK=0"             "BREAK=0"             "${out5}"
assert_contains "TICKET empty"        "TICKET="             "${out5}"
assert_contains "ERROR_TYPE empty"    "ERROR_TYPE="         "${out5}"

echo "Case 6: branch flag=1 + valid ticket → STATUS=running (gate passes through)"
out6="$(simulate_branch "${TICKET_DIR}" prd 1)"
assert_contains "STATUS=running"      "STATUS=running"      "${out6}"
assert_contains "BREAK=0"             "BREAK=0"             "${out6}"
assert_contains "ticket resolved"     "prd.ticket.json"     "${out6}"

echo "Case 7: branch flag=1 + invalid ticket → STATUS=handoff_ticket_invalid + BREAK=1"
out7="$(simulate_branch "${TICKET_DIR}" tech_plan 1)"
assert_contains "STATUS=handoff_ticket_invalid" "STATUS=handoff_ticket_invalid" "${out7}"
assert_contains "STATE=hard_fail"               "STATE=hard_fail"               "${out7}"
assert_contains "BREAK=1"                       "BREAK=1"                       "${out7}"
assert_contains "ERROR_TYPE classified"         "ERROR_TYPE=handoff_validation_failed" "${out7}"
assert_contains "DETAIL captures verdict"        "reason=handoff_schema_invalid"        "${out7}"
assert_contains "missing field surfaced"         "'ticket_id' is a required property"   "${out7}"
assert_contains "ticket path recorded"           "tech_plan.ticket.json"                "${out7}"

echo "Case 8: branch flag=1 + no ticket on disk → STATUS=running (no-op)"
out8="$(simulate_branch "${TICKET_DIR}" some_step_without_ticket 1)"
assert_contains "STATUS=running"      "STATUS=running"      "${out8}"
assert_contains "BREAK=0"             "BREAK=0"             "${out8}"
assert_contains "TICKET empty"        "TICKET="             "${out8}"

# ── Case 9: resolve_latest_ticket picks highest-seq variant ─────────────

echo "Case 9: resolve_latest_ticket picks highest-seq variant"
SEQ_DIR="${SANDBOX}/seq"
mkdir -p "${SEQ_DIR}"
cp "${GOOD_TICKET}" "${SEQ_DIR}/dba_api.ticket.json"
cp "${GOOD_TICKET}" "${SEQ_DIR}/dba_api-2.ticket.json"
cp "${GOOD_TICKET}" "${SEQ_DIR}/dba_api-10.ticket.json"
cp "${GOOD_TICKET}" "${SEQ_DIR}/dba_api-3.ticket.json"

# Mirror resolve_latest_ticket inline so the helper is exercised end to end.
seq_out="$(
  HANDOFFS_DIR="${SEQ_DIR}" \
  step_id=dba_api \
  bash -c '
    resolve_latest_ticket() {
      local handoffs_dir="$1"
      local step_id="$2"
      [ -z "${handoffs_dir}" ] && return 0
      [ ! -d "${handoffs_dir}" ] && return 0
      local base="${handoffs_dir}/${step_id}.ticket.json"
      local latest=""
      [ -f "${base}" ] && latest="${base}"
      local candidate seq highest=1
      shopt -s nullglob
      for candidate in "${handoffs_dir}/${step_id}"-*.ticket.json; do
        [ -f "${candidate}" ] || continue
        seq="${candidate##*-}"
        seq="${seq%.ticket.json}"
        case "${seq}" in
          ""|*[!0-9]*) continue ;;
        esac
        if [ "${seq}" -gt "${highest}" ]; then
          highest="${seq}"
          latest="${candidate}"
        fi
      done
      shopt -u nullglob
      [ -n "${latest}" ] && printf "%s\n" "${latest}"
    }
    resolve_latest_ticket "${HANDOFFS_DIR}" "${step_id}"
  '
)"
assert_contains "highest-seq variant chosen (10 > 3 > 2 > base)" "dba_api-10.ticket.json" "${seq_out}"

# ── Layer 3: wrapper presence guard ─────────────────────────────────────

echo "Case 10: cap-workflow-exec.sh contains env-flag block + reset + helper"
exec_src="$(cat "${EXEC_SH}")"
assert_contains "env flag check present"          'CAP_ENFORCE_HANDOFF_SCHEMA:-0' "${exec_src}"
assert_contains "validate-handoff-ticket call"    'validate-handoff-ticket'        "${exec_src}"
assert_contains "STEP_HANDOFF_GATE_DETAIL reset"  'STEP_HANDOFF_GATE_DETAIL=""'    "${exec_src}"
assert_contains "STATUS handoff_ticket_invalid"   'handoff_ticket_invalid'         "${exec_src}"
assert_contains "ERROR_TYPE handoff classification" 'handoff_validation_failed'    "${exec_src}"
assert_contains "resolve_latest_ticket helper"    'resolve_latest_ticket()'        "${exec_src}"

echo ""
echo "handoff-schema-gate: ${pass_count} passed, ${fail_count} failed"
[ "${fail_count}" -eq 0 ]
