#!/usr/bin/env bash
#
# test-ai-step-result-workflow-integration.sh — Lock the v0.26.0
# wire-up between the AI step result parser and cap-workflow-exec.sh's
# step-success path.
#
# Pre-fix (bug #12): an AI step that exited 0 with non-empty stdout
# was treated as ``ok`` even when the AI's markdown body declared
# ``result: blocked_*`` / ``FAIL_BLOCKED_*`` / ``needs_data``.
#
# Fix (v0.26.0 R1.3): cap-workflow-exec.sh post-step branch parses
# the captured stdout via ``step_runtime parse-step-result`` when the
# effective executor is AI; non-success states convert to a hard
# failure that ``record_blocked_step`` + ``register_step_runtime_state``
# surface, and the loop halts on a non-optional step.
#
# Coverage strategy: invoking cap-workflow-exec end-to-end requires a
# real workflow YAML, runtime binder, AI provider; that's expensive
# and provider-bound. Instead this fixture verifies the **wired
# behaviour** by greping the script source for the contract, plus
# unit-tests the helper integration via the parser CLI directly.
# A full end-to-end smoke through cap-workflow-exec lives at the
# dogfood layer (Phase D re-run) rather than the unit-test layer.
#
# Coverage:
#   Case 1: cap-workflow-exec.sh contains the AI_RESULT_HARD_FAIL
#           branch and gates the success block on it.
#   Case 2: success block is gated on BOTH validator and ai_result
#           hard fails (defence-in-depth lint).
#   Case 3: parse-step-result emits state=blocked for a fixture
#           mirroring the Phase D 4-backend.md format.
#   Case 4: parse-step-result emits state=failed for the FAIL_*
#           dogfood fixture.
#   Case 5: parse-step-result emits state=success for a clean run.
#   Case 6: AI_RESULT_HARD_FAIL classification respects the
#           shell-vs-AI executor branch (only fires for AI steps).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
EXEC_SH="${REPO_ROOT}/scripts/cap-workflow-exec.sh"
STEP_PY="${REPO_ROOT}/engine/step_runtime.py"

[ -f "${EXEC_SH}" ] || { echo "FAIL: cap-workflow-exec.sh missing"; exit 1; }
[ -f "${STEP_PY}" ] || { echo "FAIL: step_runtime.py missing"; exit 1; }

SANDBOX="$(mktemp -d -t cap-ai-result-wire.XXXXXX)"
SANDBOX="$(cd "${SANDBOX}" && pwd -P)"
trap 'rm -rf "${SANDBOX}"' EXIT

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
  local desc="$1" needle="$2" haystack="$3"
  case "${haystack}" in
    *"${needle}"*)
      echo "  PASS: ${desc}"
      pass_count=$((pass_count + 1)) ;;
    *)
      echo "  FAIL: ${desc}"
      echo "    expected substring: ${needle}"
      echo "    actual:             ${haystack}"
      fail_count=$((fail_count + 1)) ;;
  esac
}

# ── Case 1: cap-workflow-exec contains the AI_RESULT_HARD_FAIL branch ─
echo "Case 1: cap-workflow-exec wires the AI result parser"
# Expect at least 3 references: declaration, hard-fail set, success-gate read.
hits1="$(grep -c 'AI_RESULT_HARD_FAIL' "${EXEC_SH}" || true)"
[ "${hits1}" -ge 3 ] && c1ok="yes" || c1ok="no"
assert_eq "1a. AI_RESULT_HARD_FAIL referenced in script (>=3 occurrences)" "yes" "${c1ok}"

if grep -q 'parse-step-result' "${EXEC_SH}"; then
  c1b="yes"
else
  c1b="no"
fi
assert_eq "1b. cap-workflow-exec calls parse-step-result subcommand" "yes" "${c1b}"

# ── Case 2: success block is gated on BOTH hard-fail flags ──────────
echo ""
echo "Case 2: success block guarded by validator AND ai_result hard fails"
gate_count="$(grep -c 'VALIDATOR_HARD_FAIL.*-eq 0.*&&.*AI_RESULT_HARD_FAIL.*-eq 0' "${EXEC_SH}" || true)"
assert_eq "2. defence-in-depth gate present" "1" "${gate_count}"

# ── Case 3: parser handles Phase D 4-backend.md style content ───────
echo ""
echo "Case 3: parser maps phase-D blocked_read_only to state=blocked"
phd_fixture="${SANDBOX}/phd-backend.md"
cat > "${phd_fixture}" <<'EOF'
## 任務理解
本步驟為 backend / backend_implementation。

## 執行重點
本次實際檢查結果：
- Repo 目前只有文件與 CAP metadata，未存在 backend/、.sln、.csproj 等。
- test -w . 回傳 1，專案根目錄不可寫。
依 workflow 指示，stdout 是本步驟主要交付通道。

## 產出內容
本步驟結果為 blocked_read_only，未產出可追蹤檔案。

## 交接摘要
- agent_id: 05-Backend
- task_summary: 已完成 backend step 的上游產物讀取、規範掛載與 repo 狀態檢查。
- output_paths:
  - 強制輸出檔目標：/home/.../4-backend.md
- result：blocked_read_only
EOF
case3_state="$(${PYTHON_BIN} "${STEP_PY}" parse-step-result "${phd_fixture}" | grep -oE '^state=[a-z_]+' | cut -d= -f2)"
assert_eq "3. 4-backend.md style → state=blocked" "blocked" "${case3_state}"

# ── Case 4: FAIL_BLOCKED_* dogfood fixture → blocked ────────────────
echo ""
echo "Case 4: FAIL_BLOCKED_* dogfood fixture → state=blocked"
qa_fixture="${SANDBOX}/phd-qa.md"
printf 'header\n- result：FAIL_BLOCKED_READ_ONLY_UPSTREAM_IMPLEMENTATION_MISSING\n' > "${qa_fixture}"
case4_state="$(${PYTHON_BIN} "${STEP_PY}" parse-step-result "${qa_fixture}" | grep -oE '^state=[a-z_]+' | cut -d= -f2)"
assert_eq "4. FAIL_BLOCKED_*  → state=blocked" "blocked" "${case4_state}"

# ── Case 5: clean success path ──────────────────────────────────────
echo ""
echo "Case 5: clean success fixture → state=success"
ok_fixture="${SANDBOX}/clean.md"
cat > "${ok_fixture}" <<'EOF'
# step output

## 交接摘要
- agent_id: 02a-BA
- task_summary: BA spec produced and persisted.
- output_paths:
  - docs/architecture/foo_BA_v1.md
- result: success
EOF
case5_state="$(${PYTHON_BIN} "${STEP_PY}" parse-step-result "${ok_fixture}" | grep -oE '^state=[a-z_]+' | cut -d= -f2)"
assert_eq "5. clean success → state=success" "success" "${case5_state}"

# ── Case 6: structural lint — gate is AI-only ───────────────────────
echo ""
echo "Case 6: AI_RESULT_HARD_FAIL is gated on effective_executor = ai"
ai_only_check="$(grep -c 'effective_executor.*ai\|executor.*=.*ai' "${EXEC_SH}" | head -1 || true)"
[ "${ai_only_check}" -ge 1 ] && c6="yes" || c6="no"
assert_eq "6a. cap-workflow-exec gates AI parsing on executor=ai" "yes" "${c6}"
assert_contains "6b. AI_RESULT_HARD_FAIL block references effective_executor" \
  'effective_executor' \
  "$(grep -A 5 'AI_RESULT_HARD_FAIL=0' "${EXEC_SH}")"

echo ""
total=$((pass_count + fail_count))
echo "ai-step-result-workflow-integration: ${pass_count} passed, ${fail_count} failed (of ${total})"
[ "${fail_count}" -eq 0 ]
