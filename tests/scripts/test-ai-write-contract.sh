#!/usr/bin/env bash
#
# test-ai-write-contract.sh — Lock the v0.26.1 Round 2 AI Write
# Contract documented in agent-skills/00-core-protocol.md §5.3.2.
#
# Pre-fix (v0.26.0): the AI step result contract correctly halted on
# self-reported blocked / failed states, but a pathological pattern
# remained — an AI agent that emitted ``result: success`` while
# producing no actual code files (the v0.25.x bug #12 root) would
# still pass through. Round 1 fixed perception of failure; Round 2
# adds a positive emit requirement for code-emitting capabilities.
#
# Coverage matrix:
#
#   Section 1 — capability whitelist
#     1a backend_implementation → emits-code = true
#     1b frontend_implementation → emits-code = true
#     1c qa_testing → emits-code = true
#     1d devops_delivery → emits-code = true
#     1e prd_generation → emits-code = false (markdown-only)
#     1f code_structure_audit → emits-code = false
#     1g security_audit → emits-code = false
#     1h archive / technical_logging → emits-code = false
#     1i unknown capability → emits-code = false (defaults safe)
#
#   Section 2 — cap-workflow-exec wiring
#     2a run_step_claude accepts write_dir param and emits --add-dir
#        + --permission-mode acceptEdits + --allowed-tools
#     2b run_step_codex accepts write_dir and emits --sandbox
#        workspace-write + --cd
#     2c main loop creates STEP_WRITE_DIR and exports
#        CAP_WORKFLOW_WRITE_DIR before the AI step
#     2d run_step dispatcher passes write_dir as third arg
#     2e build_step_prompt embeds the write contract section
#     2f post-AI gate (AI_EMIT_HARD_FAIL) demotes success-with-empty-dir
#        for code-emitting capabilities
#     2g success block requires all three hard-fail flags to be 0
#        (validator + ai_result + ai_emit)
#
#   Section 3 — provider flag contract
#     3a claude --add-dir + --permission-mode + --allowed-tools list
#        is gated by non-empty write_dir
#     3b codex --sandbox workspace-write + --cd is gated by non-empty
#        write_dir

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EXEC_SH="${REPO_ROOT}/scripts/cap-workflow-exec.sh"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${EXEC_SH}" ] || { echo "FAIL: cap-workflow-exec.sh missing"; exit 1; }
[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

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

# ── Section 1: capability whitelist ────────────────────────────────
echo "Section 1: capability whitelist (capability-emits-code CLI)"
assert_eq "1a backend_implementation"   "true"  "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code backend_implementation)"
assert_eq "1b frontend_implementation"  "true"  "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code frontend_implementation)"
assert_eq "1c qa_testing"               "true"  "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code qa_testing)"
assert_eq "1d devops_delivery"          "true"  "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code devops_delivery)"
assert_eq "1e prd_generation"           "false" "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code prd_generation)"
assert_eq "1f code_structure_audit"     "false" "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code code_structure_audit)"
assert_eq "1g security_audit"           "false" "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code security_audit)"
assert_eq "1h technical_logging"        "false" "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code technical_logging)"
assert_eq "1i unknown_capability"       "false" "$(${PYTHON_BIN} ${STEP_PY} capability-emits-code totally_made_up_capability)"

# ── Section 2: cap-workflow-exec wiring (structural lint) ──────────
echo ""
echo "Section 2: cap-workflow-exec wiring"

# 2a — claude function takes write_dir and emits the right flags
claude_block="$(awk '/^run_step_claude\(\)/,/^}$/' "${EXEC_SH}")"
case "${claude_block}" in
  *"--add-dir"*"--permission-mode acceptEdits"*"--allowed-tools"*)
    echo "  PASS: 2a run_step_claude has --add-dir + --permission-mode acceptEdits + --allowed-tools"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 2a run_step_claude missing one of --add-dir / --permission-mode / --allowed-tools"
    fail_count=$((fail_count + 1)) ;;
esac

# 2b — codex function takes write_dir and emits sandbox + cd
codex_block="$(awk '/^run_step_codex\(\)/,/^}$/' "${EXEC_SH}")"
case "${codex_block}" in
  *"--sandbox workspace-write"*"--cd"*)
    echo "  PASS: 2b run_step_codex has --sandbox workspace-write + --cd"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 2b run_step_codex missing --sandbox workspace-write or --cd"
    fail_count=$((fail_count + 1)) ;;
esac

# 2c — main loop sets CAP_WORKFLOW_WRITE_DIR and STEP_WRITE_DIR
hits_2c="$(grep -c 'CAP_WORKFLOW_WRITE_DIR=' "${EXEC_SH}" || true)"
[ "${hits_2c}" -ge 1 ] && c2c="yes" || c2c="no"
assert_eq "2c CAP_WORKFLOW_WRITE_DIR exported" "yes" "${c2c}"
hits_step_write="$(grep -c 'STEP_WRITE_DIR=' "${EXEC_SH}" || true)"
[ "${hits_step_write}" -ge 1 ] && c2c2="yes" || c2c2="no"
assert_eq "2c STEP_WRITE_DIR computed" "yes" "${c2c2}"

# 2d — run_step dispatcher accepts write_dir as 3rd arg and forwards
dispatcher_block="$(awk '/^run_step\(\)/,/^}$/' "${EXEC_SH}")"
case "${dispatcher_block}" in
  *'write_dir="${3:-}"'*'run_step_claude "${prompt}" "${write_dir}"'*'run_step_codex "${prompt}" "${write_dir}"'*)
    echo "  PASS: 2d run_step dispatcher forwards write_dir"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 2d run_step dispatcher does not forward write_dir"
    fail_count=$((fail_count + 1)) ;;
esac

# 2e — build_write_contract_section exists and is wired into prompt
hits_2e="$(grep -c 'build_write_contract_section' "${EXEC_SH}" || true)"
[ "${hits_2e}" -ge 2 ] && c2e="yes" || c2e="no"
assert_eq "2e build_write_contract_section defined and called" "yes" "${c2e}"

# 2f — AI_EMIT_HARD_FAIL block exists
hits_2f="$(grep -c 'AI_EMIT_HARD_FAIL' "${EXEC_SH}" || true)"
[ "${hits_2f}" -ge 3 ] && c2f="yes" || c2f="no"
assert_eq "2f AI_EMIT_HARD_FAIL gate present (>=3 references)" "yes" "${c2f}"

# 2g — success block gated on all three hard-fail flags
gate_count="$(grep -c 'VALIDATOR_HARD_FAIL.*-eq 0.*&&.*AI_RESULT_HARD_FAIL.*-eq 0.*&&.*AI_EMIT_HARD_FAIL.*-eq 0' "${EXEC_SH}" || true)"
assert_eq "2g defence-in-depth gate (validator + ai_result + ai_emit)" "1" "${gate_count}"

# ── Section 3: provider flags only fire with write_dir ─────────────
echo ""
echo "Section 3: provider flags are gated on non-empty write_dir"
case "${claude_block}" in
  *'if [ -n "${write_dir}" ]; then'*)
    echo "  PASS: 3a claude flags guarded by write_dir non-empty check"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 3a claude flags not properly guarded"
    fail_count=$((fail_count + 1)) ;;
esac

case "${codex_block}" in
  *'if [ -n "${write_dir}" ]; then'*)
    echo "  PASS: 3b codex flags guarded by write_dir non-empty check"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 3b codex flags not properly guarded"
    fail_count=$((fail_count + 1)) ;;
esac

# ── Section 4 (v0.26.2): bug #15 fix — write access gated on
# capability_emits_code; non-emit AI steps get read-only tool set ─
echo ""
echo "Section 4 (v0.26.2): write access gated on capability whitelist"

# 4a — main loop sets STEP_WRITE_DIR ONLY when capability emits code
case "$(awk '/STEP_WRITE_DIR=""/,/^  fi$/' "${EXEC_SH}" | head -20)" in
  *'STEP_EMITS_CODE='*'capability-emits-code'*'if [ "${STEP_EMITS_CODE}" = "true" ]; then'*)
    echo "  PASS: 4a STEP_WRITE_DIR gated on capability-emits-code"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 4a STEP_WRITE_DIR not gated on capability-emits-code"
    fail_count=$((fail_count + 1)) ;;
esac

# 4b — read-only tool set for non-emit AI steps in run_step_claude
claude_block_full="$(awk '/^run_step_claude\(\)/,/^}$/' "${EXEC_SH}")"
case "${claude_block_full}" in
  *'else'*'--allowed-tools "Read,Glob,Grep"'*)
    echo "  PASS: 4b run_step_claude has read-only tools fallback (Read,Glob,Grep)"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 4b run_step_claude missing read-only fallback for non-emit steps"
    fail_count=$((fail_count + 1)) ;;
esac

# 4c — fallback path also gated on capability-emits-code
fallback_block="$(awk '/FALLBACK_WRITE_DIR=""/,/^      fi$/' "${EXEC_SH}" | head -10)"
case "${fallback_block}" in
  *'FALLBACK_EMITS_CODE='*'capability-emits-code'*)
    echo "  PASS: 4c shell-to-AI fallback path also gated on capability-emits-code"
    pass_count=$((pass_count + 1)) ;;
  *)
    echo "  FAIL: 4c shell-to-AI fallback path not gated"
    fail_count=$((fail_count + 1)) ;;
esac

# 4d — explicit unset CAP_WORKFLOW_WRITE_DIR for non-emit branch
hits_4d="$(grep -c 'unset CAP_WORKFLOW_WRITE_DIR' "${EXEC_SH}" || true)"
[ "${hits_4d}" -ge 2 ] && c4d="yes" || c4d="no"
assert_eq "4d unset CAP_WORKFLOW_WRITE_DIR present in main + fallback (>=2)" "yes" "${c4d}"

echo ""
total=$((pass_count + fail_count))
echo "ai-write-contract: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
