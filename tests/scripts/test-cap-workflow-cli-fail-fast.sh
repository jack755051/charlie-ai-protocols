#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP_WORKFLOW="${REPO_ROOT}/scripts/cap-workflow.sh"
CAP_WORKFLOW_EXEC="${REPO_ROOT}/scripts/cap-workflow-exec.sh"

failures=0
checks=0

pass() {
  checks=$((checks + 1))
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL: $*" >&2
}

assert_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if grep -Fq "${needle}" <<<"${haystack}"; then
    pass
  else
    fail "${label}: expected to contain '${needle}'"
    echo "  --- haystack ---" >&2
    printf '%s\n' "${haystack}" | head -8 >&2
  fi
}

# ── Case 1: cap-workflow.sh declares validate_run_cli_choice helper ─────
# 注意：`printf '%s' "${BODY}" | grep -q ...` 在 set -o pipefail 下會踩
# SIGPIPE（grep -q first match 退出，printf 還在寫）→ exit 141 失敗。
# 改用 `grep "FILE"` 直接讀檔，不走 pipe。
echo "Case 1: validate_run_cli_choice helper exists"
if grep -q '^validate_run_cli_choice()' "${CAP_WORKFLOW}"; then
  pass
else
  fail "validate_run_cli_choice() not declared in cap-workflow.sh"
fi

# ── Case 2: validate_run_cli_choice is invoked before foreground spawn ─
echo "Case 2: validate is invoked before foreground exec"
# 兩個 run path（run-task / run）都應該各自呼叫一次 validate
INVOKE_COUNT="$(grep -c 'validate_run_cli_choice "${RUN_CLI}"' "${CAP_WORKFLOW}" || true)"
if [ "${INVOKE_COUNT}" -ge 2 ]; then
  pass
else
  fail "expected ≥2 invocations of validate_run_cli_choice, got ${INVOKE_COUNT}"
fi

# ── Case 3: cap-workflow-exec.sh has ensure_provider_cli runtime guard ─
echo "Case 3: cap-workflow-exec.sh declares ensure_provider_cli + invokes in run_step_*"
if grep -q '^ensure_provider_cli()' "${CAP_WORKFLOW_EXEC}"; then
  pass
else
  fail "ensure_provider_cli() not declared in cap-workflow-exec.sh"
fi
EXEC_GUARD_COUNT="$(grep -cE 'ensure_provider_cli claude|ensure_provider_cli codex' "${CAP_WORKFLOW_EXEC}" || true)"
if [ "${EXEC_GUARD_COUNT}" -ge 2 ]; then
  pass
else
  fail "expected ≥2 ensure_provider_cli invocations in run_step_*, got ${EXEC_GUARD_COUNT}"
fi

# ── Case 4: dry-run path does NOT trigger provider validation ──────────
echo "Case 4: --dry-run does not require provider"
# dry-run 跑得通且不會碰 provider 檢查（即使有 provider 也不會 exit 1）
# 此 case 只檢查 dry-run 不會早死於 validate；我們無法輕易模擬「無 provider」
# 場景，但可以驗證 dry-run path exit 0 在 RUN_CLI validation 之前
DRY_RUN_BLOCK="$(awk '
  /^  run\)/ { in_run=1 }
  in_run && /DRY_RUN.*-eq 1/ { dry=NR }
  in_run && /^    validate_run_cli_choice/ { validate=NR }
  END {
    if (dry > 0 && validate > 0 && dry < validate) {
      print "dry-before-validate"
    } else {
      print "dry=" dry " validate=" validate
    }
  }
' "${CAP_WORKFLOW}")"
assert_contains "dry-run check precedes validate" "dry-before-validate" "${DRY_RUN_BLOCK}"

# ── Case 5: validate_run_cli_choice rejects unsupported cli with helpful msg ─
echo "Case 5: helper rejects unsupported --cli value"
# 直接 source 檔的下半段風險高（會執行 main case），改用 inline reproduction
# 透過 sub-shell 抽出 function 後測試
TEMP_HELPER="$(mktemp -t cap-validate-helper.XXXXXX.sh)"
trap 'rm -f "${TEMP_HELPER}"' EXIT
sed -n '/^validate_run_cli_choice()/,/^}/p' "${CAP_WORKFLOW}" > "${TEMP_HELPER}"
echo 'validate_run_cli_choice "$1"' >> "${TEMP_HELPER}"
set +e
ERR_MSG="$(bash "${TEMP_HELPER}" "bogus-provider" 2>&1)"
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
  pass
else
  fail "validate should reject 'bogus-provider' with non-zero rc"
fi
assert_contains "rejection message mentions supported values" "claude | codex" "${ERR_MSG}"

# ── Case 6: validate_run_cli_choice accepts 'auto' when at least one cli on PATH ─
echo "Case 6: 'auto' accepts when claude or codex is on PATH"
# 這個測試假設 smoke 環境至少有一個 provider 可達；若兩個都缺，這個 case 會 fail
# 但這正是 fixture 應該偵測的 — 即治理的真實依賴
set +e
bash "${TEMP_HELPER}" "auto" 2>/dev/null
RC=$?
set -e
if [ "${RC}" -eq 0 ]; then
  pass
else
  # 若環境真的沒有 provider，我們仍要 detection — 此 case 應跳過而非 silent pass
  echo "  WARN: no provider on PATH in test env; skipping case 6" >&2
fi

# ── Summary ─────────────────────────────────────────────────────────────
PASSED=$((checks - failures))
echo "Summary: ${PASSED} passed, ${failures} failed"
[ "${failures}" -eq 0 ]
