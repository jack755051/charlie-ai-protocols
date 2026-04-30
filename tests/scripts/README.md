# Workflow Executor Smoke Tests

簡易 bash + python 整合測試，驗證 `scripts/workflows/` 下的 deterministic shell executor 在 happy path 與 negative path 下的行為。

## 範圍

目前涵蓋：

- `test-persist-task-constitution.sh` — `scripts/workflows/persist-task-constitution.sh`
  - 正常路徑（valid task constitution draft → exit 0 + 檔案落地）
  - parse error（malformed JSON → exit 40 + PARSE_ERROR）
  - missing required field（缺 task_id → exit 40 + MISSING_REQUIRED）
  - invalid goal_stage（非 enum → exit 40 + INVALID_GOAL_STAGE）
  - invalid execution_plan entry（缺 step_id → exit 40 + INVALID_EXECUTION_PLAN_ENTRY）

- `test-emit-handoff-ticket.sh` — `scripts/workflows/emit-handoff-ticket.sh`
  - 正常路徑（產出符合 schema 的 ticket）
  - missing target_step_id env → exit 40
  - target step 不在 execution_plan → exit 40
  - seq 遞增（重跑同 step → `<step>-2.ticket.json`）

## 執行

```bash
cd /path/to/charlie-ai-protocols
bash tests/scripts/test-persist-task-constitution.sh
bash tests/scripts/test-emit-handoff-ticket.sh
```

每個 test 會在 `/tmp/cap-test-*` 開隔離的 sandbox（透過 `mktemp -d`），結束後自動清理。

## 退出碼

- 0：全數 case PASS
- 非 0：第一個 FAIL 的 case 後立即停止並印出 detail

## 一鍵跑全部 smoke（含 cap CLI binding）

```bash
bash scripts/workflows/smoke-per-stage.sh
```

該 wrapper 會依序執行三條 per-stage workflow 的 `cap workflow bind` 檢查 + 兩個 fixture 套件。`cap` CLI 不在 PATH 時 bind 檢查會 graceful skip 並標 WARN，但 fixture 套件仍會跑完。退出碼 0 = 全 PASS（含 skipped），非 0 = 至少一項 FAIL。

## 範圍邊界

這些是 smoke / fixture 測試，不取代：
- `cap workflow run --dry-run` / `cap workflow plan` 的整合測試
- engine 層自動 ticket emission 的測試（engine integration 尚未實作）
- 跨 workflow 串接的 e2e 測試（cap workflow run 端到端）
- sub-agent 端 ticket consumption 與 Type D handoff summary 寫出的整合測試
