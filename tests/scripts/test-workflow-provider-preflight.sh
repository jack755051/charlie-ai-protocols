#!/usr/bin/env bash
#
# test-workflow-provider-preflight.sh — P2 gate.
#
# Exercises the workflow provider readiness preflight wired up in
# scripts/cap-workflow.sh + scripts/cap-provider-preflight.sh per:
#
#   - development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md
#     (ADR-3 — AI workflows MUST fail fast before any provider call)
#   - schemas/provider-readiness.schema.yaml (the JSON contract)
#
# Two layers:
#
#   Layer 1 — helper unit tests:
#     workflow_has_ai_step / provider_preflight_check exercised against
#     synthetic plan + doctor JSON fixtures covering every branch in
#     the helper.
#
#   Layer 2 — workflow-level integration:
#     CAP_PROVIDER_DOCTOR_JSON_OVERRIDE injects fixture doctor JSON so
#     the real cap-workflow run path can be exercised without touching
#     the host's installed claude/codex binaries. Asserts that:
#       - dry-run never reads the override (preflight is upstream-only
#         for dry-run, so dry-run output never carries preflight text)
#       - bind never reads the override
#       - run + AI workflow + provider_missing override → halt block
#       - run + AI workflow + auth_unknown override → warning block,
#         no halt (test stops the actual run via empty USER_PROMPT
#         which short-circuits earlier, so we only assert the warning
#         emission path is reachable without breaking the early-exit)
#
# Out of scope:
#   - no real provider invocation (no Claude / Codex / tokens spent)
#   - no workflow_runtime execution beyond cap-workflow.sh dispatch
#   - no changes to existing P1b tests or scripts

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HELPER="${REPO_ROOT}/scripts/cap-provider-preflight.sh"
WORKFLOW_SH="${REPO_ROOT}/scripts/cap-workflow.sh"
CAP_ENTRY="${REPO_ROOT}/scripts/cap-entry.sh"

[ -f "${HELPER}" ]      || { echo "FAIL: ${HELPER} missing"; exit 1; }
[ -f "${WORKFLOW_SH}" ] || { echo "FAIL: ${WORKFLOW_SH} missing"; exit 1; }
[ -f "${CAP_ENTRY}" ]   || { echo "FAIL: ${CAP_ENTRY} missing"; exit 1; }

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
    fail_count=$((fail_count + 1))
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  FAIL: ${desc}"
    echo "    forbidden: ${needle}"
    fail_count=$((fail_count + 1))
  else
    echo "  PASS: ${desc}"
    pass_count=$((pass_count + 1))
  fi
}

# Source the helper in a subshell-safe way; the helper sets variables
# and defines functions but does not exit on its own.
. "${HELPER}"

# ── Case 1: workflow_has_ai_step — has-ai path ───────────────────────
echo "Case 1: workflow_has_ai_step on a plan with one AI step"
if workflow_has_ai_step '{"binding":{"steps":[{"executor":"shell"},{"executor":"ai"}]}}'; then
  pass_count=$((pass_count + 1))
  echo "  PASS: returns 0 when binding contains an AI step"
else
  fail_count=$((fail_count + 1))
  echo "  FAIL: returns 0 when binding contains an AI step"
fi

# ── Case 2: workflow_has_ai_step — shell-only path ──────────────────
echo ""
echo "Case 2: workflow_has_ai_step on shell-only plan returns 1"
if workflow_has_ai_step '{"binding":{"steps":[{"executor":"shell"},{"executor":"shell"}]}}'; then
  fail_count=$((fail_count + 1))
  echo "  FAIL: must NOT return 0 for shell-only binding"
else
  pass_count=$((pass_count + 1))
  echo "  PASS: returns non-zero for shell-only binding"
fi

# ── Case 3: workflow_has_ai_step — default executor (missing) → ai ──
#
# CAP capability schema's default executor is "ai" when the field is
# absent (engine/step_runtime.py:1151). The helper MUST match that
# default or shell-only detection would be false-positive on any
# legacy plan without an explicit executor.
echo ""
echo "Case 3: workflow_has_ai_step treats missing executor as ai (default)"
if workflow_has_ai_step '{"binding":{"steps":[{}]}}'; then
  pass_count=$((pass_count + 1))
  echo "  PASS: missing executor defaults to ai"
else
  fail_count=$((fail_count + 1))
  echo "  FAIL: missing executor must default to ai"
fi

# ── Case 4: workflow_has_ai_step — fallback executor=ai also counts ─
echo ""
echo "Case 4: workflow_has_ai_step honours fallback.executor=ai"
if workflow_has_ai_step '{"binding":{"steps":[{"executor":"shell","fallback":{"executor":"ai"}}]}}'; then
  pass_count=$((pass_count + 1))
  echo "  PASS: fallback ai detected even when primary is shell"
else
  fail_count=$((fail_count + 1))
  echo "  FAIL: fallback ai must promote workflow to has-ai"
fi

# ── Case 5: provider_preflight_check — auth_ok → rc 0, result=ok ────
echo ""
echo "Case 5: provider_preflight_check auth_ok"
if R="$(provider_preflight_check claude '{"providers":[{"name":"claude","state":"auth_ok","remediation":"ready"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "auth_ok rc=0"          "0"              "${RC}"
assert_contains "auth_ok result=ok"      "${R}"           "result=ok"
assert_contains "auth_ok state echoed"   "${R}"           "state=auth_ok"

# ── Case 6: provider_preflight_check — auth_unknown → rc 1, warn ────
echo ""
echo "Case 6: provider_preflight_check auth_unknown"
if R="$(provider_preflight_check claude '{"providers":[{"name":"claude","state":"auth_unknown","remediation":"run cap claude to verify"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "auth_unknown rc=1"           "1"                            "${RC}"
assert_contains "auth_unknown result=warn"      "${R}"                         "result=warn"
assert_contains "auth_unknown remediation"      "${R}"                         "remediation=run cap claude to verify"

# ── Case 7: provider_preflight_check — provider_missing → rc 2, halt ─
echo ""
echo "Case 7: provider_preflight_check provider_missing"
if R="$(provider_preflight_check claude '{"providers":[{"name":"claude","state":"provider_missing","remediation":"Install Claude Code"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "provider_missing rc=2"         "2"                            "${RC}"
assert_contains "provider_missing result=halt"    "${R}"                         "result=halt"
assert_contains "provider_missing remediation"    "${R}"                         "Install Claude Code"

# ── Case 8: provider_preflight_check — auth_required → rc 2, halt ──
echo ""
echo "Case 8: provider_preflight_check auth_required"
if R="$(provider_preflight_check codex '{"providers":[{"name":"codex","state":"auth_required","remediation":"run cap codex"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "auth_required rc=2"           "2"                            "${RC}"
assert_contains "auth_required result=halt"      "${R}"                         "result=halt"

# ── Case 9: provider_preflight_check — error state → rc 2, halt ─────
echo ""
echo "Case 9: provider_preflight_check error state preserves failure_reason"
if R="$(provider_preflight_check claude '{"providers":[{"name":"claude","state":"error","remediation":"see failure_reason","failure_reason":"version probe timed out"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "error rc=2"                       "2"                            "${RC}"
assert_contains "error result=halt"                  "${R}"                         "result=halt"
assert_contains "failure_reason echoed"              "${R}"                         "failure_reason=version probe timed out"

# ── Case 10: provider_preflight_check — unknown_cli → rc 3 ──────────
echo ""
echo "Case 10: provider_preflight_check unknown_cli"
if R="$(provider_preflight_check deepseek '{"providers":[{"name":"claude","state":"auth_ok","remediation":"r"}]}')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "unknown_cli rc=3"              "3"                            "${RC}"
assert_contains "unknown_cli result"              "${R}"                         "result=unknown_cli"

# ── Case 11: provider_preflight_check — parse error → rc 10 ─────────
echo ""
echo "Case 11: provider_preflight_check parse error"
if R="$(provider_preflight_check claude 'not-json')"; then
  RC=0
else
  RC=$?
fi
assert_eq        "parse_error rc=10"               "10"                           "${RC}"
assert_contains "parse_error result"                "${R}"                         "result=doctor_json_parse_error"

# ── Case 12: render_halt emits the documented block fields ──────────
echo ""
echo "Case 12: provider_preflight_render_halt emits halt block fields"
HALT_OUT="$(provider_preflight_render_halt 'Component Fast Path' 'claude' \
  'result=halt;state=provider_missing;remediation=Install Claude Code' 2>&1)"
assert_contains "halt header"                      "${HALT_OUT}"  "WORKFLOW PREFLIGHT BLOCKED — Component Fast Path"
assert_contains "blocked_reason field"             "${HALT_OUT}"  "blocked_reason: provider_not_ready"
assert_contains "provider field"                   "${HALT_OUT}"  "provider: claude"
assert_contains "state field"                      "${HALT_OUT}"  "state: provider_missing"
assert_contains "remediation field"                "${HALT_OUT}"  "remediation: Install Claude Code"
assert_contains "halt explicitly no tokens"        "${HALT_OUT}"  "No tokens were spent"
assert_contains "halt cites schema SSOT"           "${HALT_OUT}"  "schemas/provider-readiness.schema.yaml"

# ── Case 13: render_warn emits warning block fields ────────────────
echo ""
echo "Case 13: provider_preflight_render_warn emits warning to stderr"
WARN_OUT="$(provider_preflight_render_warn 'Component Fast Path' 'claude' \
  'result=warn;state=auth_unknown;remediation=run cap claude' 2>&1)"
assert_contains "warn header"                      "${WARN_OUT}"  "WORKFLOW PREFLIGHT WARNING"
assert_contains "warn names provider"               "${WARN_OUT}"  "provider: claude"
assert_contains "warn names state"                  "${WARN_OUT}"  "state: auth_unknown"
assert_contains "warn carries remediation"          "${WARN_OUT}"  "remediation: run cap claude"
assert_contains "warn explains proceed reason"      "${WARN_OUT}"  "no-token / no-interactive readiness"

# ── Case 14: structural — cap-workflow.sh sources the helper ────────
echo ""
echo "Case 14: cap-workflow.sh wiring (structural)"
WORKFLOW_BODY="$(cat "${WORKFLOW_SH}")"
assert_contains "helper sourced"                    "${WORKFLOW_BODY}"  ". \"\${SCRIPT_DIR}/cap-provider-preflight.sh\""
assert_contains "preflight conditional present"     "${WORKFLOW_BODY}"  "workflow_has_ai_step \"\${PLAN_JSON}\""
assert_contains "preflight check called"            "${WORKFLOW_BODY}"  "provider_preflight_check"
assert_contains "halt renderer called"              "${WORKFLOW_BODY}"  "provider_preflight_render_halt"
assert_contains "warn renderer called"              "${WORKFLOW_BODY}"  "provider_preflight_render_warn"
assert_contains "halt exits non-zero"               "${WORKFLOW_BODY}"  "exit 4"
assert_contains "doctor override env hook present"  "${WORKFLOW_BODY}"  "CAP_PROVIDER_DOCTOR_JSON_OVERRIDE"

# ── Case 15: cap workflow bind never reaches preflight (no AI step probe) ─
echo ""
echo "Case 15: cap workflow bind does not invoke preflight (different code path)"
BIND_OUT="$(bash "${CAP_ENTRY}" workflow bind component-fast 2>&1 || true)"
assert_not_contains "bind output has no preflight halt block"     "${BIND_OUT}"  "WORKFLOW PREFLIGHT BLOCKED"
assert_not_contains "bind output has no preflight warn block"     "${BIND_OUT}"  "WORKFLOW PREFLIGHT WARNING"
assert_not_contains "bind output has no provider_not_ready"       "${BIND_OUT}"  "blocked_reason: provider_not_ready"

# ── Case 16: --dry-run does not trigger preflight ───────────────────
echo ""
echo "Case 16: --dry-run does not trigger preflight (dry-run exits upstream)"
# Force the override to "provider_missing" — if preflight were running
# during dry-run, this would produce a halt block in the output.
DRY_OUT="$(CAP_PROVIDER_DOCTOR_JSON_OVERRIDE='{"schema_version":1,"generated_at":"2026-05-15T00:00:00Z","probe_policy":{"no_token":true,"no_interactive":true,"no_mutation":true},"providers":[{"name":"claude","source":"cli","state":"provider_missing","remediation":"Install Claude Code"}]}' \
  bash "${CAP_ENTRY}" workflow run --dry-run --cli claude component-fast "smoke" 2>&1 || true)"
assert_not_contains "dry-run output has no halt block"            "${DRY_OUT}"  "WORKFLOW PREFLIGHT BLOCKED"
assert_not_contains "dry-run output has no provider_not_ready"    "${DRY_OUT}"  "blocked_reason: provider_not_ready"
assert_contains "dry-run still emits its own dry-run trailer"      "${DRY_OUT}"  "Dry run only"

# ── Case 17: integration — provider_missing override → halt block ───
echo ""
echo "Case 17: real run path + provider_missing override → halt block emitted, exit 4"
# Pass a real workflow id with a non-empty prompt so the dispatcher
# enters the run branch (line 920+ in cap-workflow.sh) and reaches the
# preflight. The override forces provider_missing without touching the
# host's installed binaries; halt happens BEFORE any AI invocation, so
# no tokens are spent and the workflow runtime never starts.
set +e
RUN_OUT="$(CAP_PROVIDER_DOCTOR_JSON_OVERRIDE='{"schema_version":1,"generated_at":"2026-05-15T00:00:00Z","probe_policy":{"no_token":true,"no_interactive":true,"no_mutation":true},"providers":[{"name":"claude","source":"cli","state":"provider_missing","remediation":"Install Claude Code: see https://docs.claude.com/claude-code"}]}' \
  bash "${CAP_ENTRY}" workflow run --cli claude component-fast "preflight halt smoke" 2>&1)"
RUN_RC=$?
set -e
assert_eq        "halt path exits 4"                          "4"                                              "${RUN_RC}"
assert_contains "halt path emits BLOCKED header"               "${RUN_OUT}"  "WORKFLOW PREFLIGHT BLOCKED"
assert_contains "halt path emits provider_not_ready"           "${RUN_OUT}"  "blocked_reason: provider_not_ready"
assert_contains "halt path names selected cli"                 "${RUN_OUT}"  "provider: claude"
assert_contains "halt path names provider_missing state"        "${RUN_OUT}"  "state: provider_missing"
assert_contains "halt path forwards remediation text"          "${RUN_OUT}"  "Install Claude Code"
assert_contains "halt path confirms no tokens spent"           "${RUN_OUT}"  "No tokens were spent"

# ── Case 18: integration — auth_required override → halt block ──────
echo ""
echo "Case 18: real run path + auth_required override → halt block"
set +e
RUN_OUT="$(CAP_PROVIDER_DOCTOR_JSON_OVERRIDE='{"schema_version":1,"generated_at":"2026-05-15T00:00:00Z","probe_policy":{"no_token":true,"no_interactive":true,"no_mutation":true},"providers":[{"name":"claude","source":"cli","cli_path":"/usr/bin/claude","state":"auth_required","remediation":"run `cap claude` once to complete login"}]}' \
  bash "${CAP_ENTRY}" workflow run --cli claude component-fast "preflight halt smoke" 2>&1)"
RUN_RC=$?
set -e
assert_eq        "auth_required halt exits 4"                  "4"                                              "${RUN_RC}"
assert_contains "auth_required halt header"                     "${RUN_OUT}"  "WORKFLOW PREFLIGHT BLOCKED"
assert_contains "auth_required state line"                      "${RUN_OUT}"  "state: auth_required"
assert_contains "auth_required remediation surfaces"            "${RUN_OUT}"  "cap claude"

# ── Case 19: integration — unknown_cli override → halt block ────────
echo ""
echo "Case 19: real run path + override missing the selected CLI → halt block"
set +e
RUN_OUT="$(CAP_PROVIDER_DOCTOR_JSON_OVERRIDE='{"schema_version":1,"generated_at":"2026-05-15T00:00:00Z","probe_policy":{"no_token":true,"no_interactive":true,"no_mutation":true},"providers":[{"name":"codex","source":"cli","state":"auth_ok","remediation":"ready"}]}' \
  bash "${CAP_ENTRY}" workflow run --cli claude component-fast "preflight halt smoke" 2>&1)"
RUN_RC=$?
set -e
assert_eq        "unknown_cli halt exits 4"                    "4"                                              "${RUN_RC}"
assert_contains "unknown_cli halt header"                       "${RUN_OUT}"  "WORKFLOW PREFLIGHT BLOCKED"

echo ""
total=$((pass_count + fail_count))
echo "workflow-provider-preflight: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
