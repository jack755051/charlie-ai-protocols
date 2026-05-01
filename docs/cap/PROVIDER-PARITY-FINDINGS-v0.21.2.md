# Provider Parity Findings — v0.21.2 baseline

> **Status (2026-05-01 closeout)**：R2 / R4 / R1 已落地（commits cf86b4d / 82e289c / eb671a7），claude e2e 從 3/16 step_failed → 16/16 completed，parity check 22 PASS / 16 FAIL → **42 PASS / 1 FAIL**。Codex cross-provider 驗證 16/16 / **41 PASS / 5 FAIL**（4 FAIL 為 parity-check §4.5 工具盲點，1 FAIL 與 claude 同源於 supervisor draft non_goals=[]）。後續 v0.21.5 已裁定 `non_goals=[]` 合法並修正 parity-check §4.2 present-only 判定；R3 latent system bug 另由 1425fa9 收斂。本檔已完成 baseline → resolution 一輪角色，後續可由 RELEASE-NOTES 摘要替代。

> 短收斂文件。目的是凍結 2026-05-01 跑 claude `project-spec-pipeline` 的觀察，作為 R2/R1/R4/R3 修復的引用基準。**不是長盤點**；後續修復完成後本檔可以由 RELEASE-NOTES 摘要替代。

## Run metadata

- 觀察日期：2026-05-01
- Tag baseline：`v0.21.2`（commit 6fcf457 之前）
- Provider：claude（`/home/jack755051/.local/bin/claude`）
- Workflow：`project-spec-pipeline`（13 phase）
- Prompt：`針對 token monitor 產出最小規格，不實作`
- Run ID：`run_20260501011703_a61affcc`
- Run dir：`~/.cap/projects/charlie-ai-protocols/reports/workflows/project-spec-pipeline/run_20260501011703_a61affcc`
- Final state：`failed` / step_failed / completed=3, failed=1, skipped=0
- **Process exit code：0**（與 final_state 不一致）
- Codex 那條：未跑。根因屬 schema/runtime 偏差，與 provider 無關，跑 codex 會撞同面牆。

## Parity-check 結果

`bash scripts/workflows/provider-parity-check.sh --run-dir <上述> --task-id token-monitor-minimal-spec-only --project-id token-monitor-minimal`

**Summary：22 passed / 16 failed**

16 FAIL 拆解：
- 1 個獨立根因：Type B Task Constitution 缺 `non_goals` 必填
- 15 個 step_failed 連帶（5 ticket missing + 6 handoff summary missing + 4 spec layer artifact missing）

## Root causes（4 個獨立打擊面）

| ID | 根因 | 證據 | 命中使用者大項 | Status |
|---|---|---|---|---|
| **R1** | `ingest_design_source` 規格 vs runtime 偏差 — `schemas/workflows/project-spec-pipeline.yaml` L108-111 `done_when` 寫「design_source 缺漏 / type none 視為 graceful no-op」，但 runtime 在 step 進到 shell 前就標 `blocked / missing_input_artifact`，shell script 根本沒執行 | `runtime-state.json` `steps.ingest_design_source.execution_state=blocked, blocked_reason=missing_input_artifact` | #1（runner 閉環） | ✓ Fixed (eb671a7) |
| **R2** | 治理信號斷裂 — `cap-workflow-exec.sh` 的 6 個 block 路徑（required_unresolved / unsupported_executor / missing_agent / invalid_shell_script / missing_input_artifact / detached_head）**不寫 workflow.log、也不寫 RUN_SUMMARY `## Steps` entry**。對比 fail 路徑（L1097/L1119/L1138/L1162/L1225）都有 `append_workflow_log`。註：exit code 已正確反映（L1310-1318 `EXIT_CODE=1`、L1380 `exit "${EXIT_CODE}"`）；先前以為 exit 0 是觀察者 background command shell 結構誤導 | run-summary.md `## Finished failed: 1` 但 `## Steps` 三個全 ok；workflow.log 完全沒有 `phase:3 step:ingest_design_source` 任一行 | #5（governance）+ #3（log 完整性） | ✓ Fixed (cf86b4d) |
| **R3** | 雙 project_id 解析 — run dir / binding 用 cwd 解析（`charlie-ai-protocols`）；task constitution / handoff 用 supervisor 草寫的 `project_id`（`token-monitor-minimal`）。同一個 run 物件分裂兩處 | `~/.cap/projects/charlie-ai-protocols/reports/workflows/.../run_dir` 與 `~/.cap/projects/token-monitor-minimal/{constitutions,handoffs}/` 並存 | #1 + #2 + #6 | ⏸ Deferred — latent system bug，留下輪。本批 closeout 跑 supervisor 草寫對齊（`charlie-ai-protocols`）沒觸發，但 system-level identity resolver 仍未統一。 |
| **R4** | supervisor §2.5 嚴格 schema 在實跑時漏 `non_goals` — 8 必填字段中有 1 個缺，normalize 也沒補預設值 | parity-check `[4.2] FAIL: Type B missing required field: non_goals` | #2（schema 拆乾淨） | ✓ Fixed (82e289c) — 但 closeout 跑揭露新議題：supervisor 寫 `non_goals: []` 空陣列、normalize 維持 `[]`、parity check §4.2 仍判定為 missing（檢查邏輯 `val in (None, "", [])`）。屬 supervisor draft 行為 + parity interpretation，不是 schema/runtime 能解的，標 deferred。 |

## Resolution and follow-up (v0.21.3 closeout)

**E2E re-run on self-hosting `charlie-ai-protocols` (claude, 2026-05-01)**：

- run_id：`run_20260501020621_b27b155f`
- duration：1217s（從 100s halt 推到完整跑通）
- final_state：`completed` / final_result：`success`
- step：**16/16 completed, 0 failed**（前 baseline 3/16, 1 failed）
- parity-check：**42 PASS / 1 FAIL**（前 baseline 22 PASS / 16 FAIL）
- 唯一 FAIL：Type B missing required field: non_goals — supervisor draft 寫了 `[]` 空陣列；parity check §4.2 把空陣列也判 missing。已分類為 deferred。

**修復順序執行紀錄**：

| Step | 動作 | 結果 |
|---|---|---|
| 1. **C** baseline | 本文件第一版（db93e55） | ✓ |
| 2. **R2 / A** | `cap-workflow-exec.sh` 加 `record_blocked_step` helper + 6 處 block 路徑 wire 入（cf86b4d） | ✓ workflow.log 與 RUN_SUMMARY 出現 blocked entry |
| 3. **R4** | `persist-task-constitution.sh` normalize 補 `risk_profile` object→string、`non_goals` array coercion；`fail_with` 改 exit 41 = schema_validation_failed；test 套件 18→22 assertions（82e289c） | ✓ phase 2 不再撞 risk_profile schema |
| 4. **R1 / B** | `engine/step_runtime.py:validate_inputs` 抽 `_try_resolve` helper，新增 `optional_inputs` 欄位處理；`schemas/workflows/project-spec-pipeline.yaml` 把 `design_source` 從 `inputs` 移到 `optional_inputs`（ingest_design_source / prd / ui 共 3 step）（eb671a7） | ✓ ingest_design_source duration 0s 走 graceful no-op |

**Cross-provider 驗證 (codex closeout)**：

- run_id：`run_20260501023353_ce13c11d`
- duration：1254s（claude 1217s，差 37s — 跨 provider 時間表現一致）
- final_state：`completed` / step：**16/16 / 0 failed**
- parity-check：**41 PASS / 5 FAIL**
- 5 FAIL 拆解：
  - 1 個跟 claude 同根因（supervisor draft 寫 `non_goals: []`），已標 deferred。
  - 4 個是 parity-check §4.5 工具盲點：codex UI step 依 03-ui-agent.md §4「必交付清單」把 `token_monitor_UI_v0.1.md` / `tokens_v0.1.json` / `screens_v0.1.json` / `prototype_v0.1.html` 寫到 `docs/design/`；§4.5 對「沒宣告 design_source + docs/design/ 存在」情境硬查 ingest 4 個 sentinel（`source-summary.md` / `source-tree.txt` / `design-source.yaml` / `.source-hash.txt`），無法區分 UI agent 交付物 vs ingest 產物 → 誤報 FAIL。
- 觀察到的 provider behavior divergence（與本批修補無關）：claude UI step 在 handoff 寫「本次未寫入，待後續專案決定」**不**寫 `docs/design/`；codex UI step 真的寫 `docs/design/`。03-ui-agent.md §4 應為強制寫檔，claude 行為偏離規範。

**結論**：R1/R2/R4 三件事在 claude 與 codex 兩條 e2e 都成功落地，沒有 provider-specific regression。剩下的 deferred 與 §4.5 false positive 都不是修補的 regression，可進入下一輪。

**Deferred 項目**：

- **R3** 雙 project_id 解析 — 系統性 identity resolver 未統一，留下一輪。
- **non_goals 空陣列 vs missing 判定** — ✓ Resolved in v0.21.5：採 (b)，`non_goals=[]` 表示「沒有排除項」且合法；checker §4.2 改為只對 `non_goals` 做 present-only 檢查，`success_criteria=[]` / `execution_plan=[]` 等 nonempty 欄位仍 FAIL。
- **其他 schema-class executors exit code** — `validate-constitution` / `emit-handoff-ticket` / `ingest-design-source` / `bootstrap-constitution-defaults` / `persist-constitution` / `load-constitution-reconcile-inputs` 仍用 exit 40，可漸進改 41 完整覆蓋。
- **parity-check §4.5 false positive** — 對 UI agent 交付物（`<module>_UI_v*.md` / `<module>_tokens_v*.json` 等）誤報為缺 ingest sentinel；應加白名單或拆「ingest 期望」與「整體 docs/design 期望」兩套檢查。
- **provider behavior divergence on docs/design/ writeback** — claude UI step 不寫實檔、codex UI step 寫；應對齊 03-ui-agent.md §4 強制要求或調整 supervisor prompt。

## 隱性觀察（記錄、不立刻修）

- `cap workflow run --help` / `--dry-run` 顯示 13 phase，但 PROVIDER-PARITY-E2E.md §4.1 寫「spec-pipeline 是 16 phase」，文件與實際 schema 不同步。
- fixture `tests/e2e/fixtures/token-monitor-minimal/.cap.constitution.yaml` 寫 `design_source: type: none`，但實際 cwd 不在 fixture 時讀的是 charlie-ai-protocols 自宿主憲法（沒 `design_source` block）。fixture 模式在 PROVIDER-PARITY-E2E.md §3 的「在目標專案目錄下」隱含要 cd 進 fixture，但執行者很容易忽略這條。
