# CAP End-to-End Tests (deterministic, runtime-free)

本目錄補的是 `tests/scripts/` unit smoke 之上、真實 `cap workflow run` AI e2e 之下的中間層：**deterministic e2e**——驗證 shell executor 鏈與 ticket consumption 的協議契約，**完全不需要 AI runtime**。

## 範圍

| 測試 | 階段（對齊 v0.19.6 設計） | Cases | Assertions |
|---|---|---|---|
| `test-project-spec-pipeline-deterministic.sh` | Stage 2: persist + emit chain | 4 stages | **40** |
| `test-ticket-consumption.sh` | Stage 3: ticket consumption (fake sub-agent) | 4 cases | **22** |

`fixtures/token-monitor-minimal/` 是上述兩個測試共用的最小 CAP 專案骨架（constitution + project config + README），repo 追蹤確保跨環境可重跑。

## 跑測試

```bash
# 個別跑
bash tests/e2e/test-project-spec-pipeline-deterministic.sh
bash tests/e2e/test-ticket-consumption.sh

# 一次跑全部（含 unit smoke 與 e2e）
bash scripts/workflows/smoke-per-stage.sh
```

每個測試在 `mktemp -d` 出的 sandbox 中執行，CAP_HOME 完全隔離，不會碰真實 `~/.cap/` 內容；結束時自動清理。

## 退出碼

- 0：所有 case PASS
- 非 0：第一個 FAIL 的 case 後立即停止並印出 detail

## 不包含 / 仍需在你的環境跑

- **真實 AI smoke**：`cap workflow run --cli codex|claude project-spec-pipeline "..."` 端到端，會 spawn 真 sub-agent；本目錄的 deterministic e2e 不取代它
- **engine `step_runtime.py` 自動 ticket emission hook**：目前 ticket 由 workflow YAML 顯式 `emit_<step>_ticket` step 產出，自動 hook 屬於 engine integration deferred 範圍
- **`cap workflow bind` / `plan` 對 fixture 專案的測試**：smoke-per-stage.sh 已對 protocol repo 自身測；對 `fixtures/token-monitor-minimal/` 的 bind 需要 PROJECT_ROOT 切換或 cap 安裝後跑

## 與 unit smoke 的對應

```
Layer                          Coverage                    Test entry
───────────────────────────    ────────────────────────    ─────────────────────────────────────
unit smoke (tests/scripts/)    persist / emit isolated     test-persist-task-constitution.sh
                                                            test-emit-handoff-ticket.sh
deterministic e2e (本目錄)      multi-step shell chain      test-project-spec-pipeline-deterministic.sh
                                ticket consumption          test-ticket-consumption.sh
real AI e2e (使用者環境)        full cap workflow run       cap workflow run project-spec-pipeline ...
```

## 改 fixture 的紀律

任何對 `fixtures/token-monitor-minimal/` 的修改都視為改 e2e 契約：

1. 必須走正式 commit + review
2. 必須同步調整 `test-*-deterministic.sh`、`test-ticket-consumption.sh` 期望值
3. CHANGELOG 記錄影響範圍
