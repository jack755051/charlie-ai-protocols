# Provider Parity Findings — v0.21.2 baseline

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

| ID | 根因 | 證據 | 命中使用者大項 |
|---|---|---|---|
| **R1** | `ingest_design_source` 規格 vs runtime 偏差 — `schemas/workflows/project-spec-pipeline.yaml` L108-111 `done_when` 寫「design_source 缺漏 / type none 視為 graceful no-op」，但 runtime 在 step 進到 shell 前就標 `blocked / missing_input_artifact`，shell script 根本沒執行 | `runtime-state.json` `steps.ingest_design_source.execution_state=blocked, blocked_reason=missing_input_artifact` | #1（runner 閉環） |
| **R2** | 治理信號斷裂 — `cap-workflow-exec.sh` 的 6 個 block 路徑（required_unresolved / unsupported_executor / missing_agent / invalid_shell_script / missing_input_artifact / detached_head）**不寫 workflow.log、也不寫 RUN_SUMMARY `## Steps` entry**。對比 fail 路徑（L1097/L1119/L1138/L1162/L1225）都有 `append_workflow_log`。註：exit code 已正確反映（L1310-1318 `EXIT_CODE=1`、L1380 `exit "${EXIT_CODE}"`）；先前以為 exit 0 是觀察者 background command shell 結構誤導 | run-summary.md `## Finished failed: 1` 但 `## Steps` 三個全 ok；workflow.log 完全沒有 `phase:3 step:ingest_design_source` 任一行 | #5（governance）+ #3（log 完整性） |
| **R3** | 雙 project_id 解析 — run dir / binding 用 cwd 解析（`charlie-ai-protocols`）；task constitution / handoff 用 supervisor 草寫的 `project_id`（`token-monitor-minimal`）。同一個 run 物件分裂兩處 | `~/.cap/projects/charlie-ai-protocols/reports/workflows/.../run_dir` 與 `~/.cap/projects/token-monitor-minimal/{constitutions,handoffs}/` 並存 | #1 + #2 + #6 |
| **R4** | supervisor §2.5 嚴格 schema 在實跑時漏 `non_goals` — 8 必填字段中有 1 個缺，normalize 也沒補預設值 | parity-check `[4.2] FAIL: Type B missing required field: non_goals` | #2（schema 拆乾淨） |

## 修復順序（已裁定）

1. **本檔 C**：完成（即此文件）
2. **R2 / A**：補 6 個 block 路徑寫 workflow.log + RUN_SUMMARY entry（exit code 部分撤銷，已正確）。S 級。
3. **R1 / B**：放寬 `ingest_design_source` runtime input gating，讓 graceful no-op 邏輯能由 shell 執行。M 級。
4. **R4**：在 `persist-task-constitution.sh` 的 normalize 對 `non_goals` 補 `[]` 預設；supervisor §2.5 prompt 仍保嚴格要求。S 級。
5. **R3**：釐清 `cwd → cap_home_project_id` 與 `task_constitution.project_id` 的優先權。M 級。會碰 `engine/cap-paths` / `step_runtime`。

R1-R4 修完後重跑 claude + codex `project-spec-pipeline` 雙條，再更新本檔（或交給 v0.22.x RELEASE-NOTES）。

## 隱性觀察（記錄、不立刻修）

- `cap workflow run --help` / `--dry-run` 顯示 13 phase，但 PROVIDER-PARITY-E2E.md §4.1 寫「spec-pipeline 是 16 phase」，文件與實際 schema 不同步。
- fixture `tests/e2e/fixtures/token-monitor-minimal/.cap.constitution.yaml` 寫 `design_source: type: none`，但實際 cwd 不在 fixture 時讀的是 charlie-ai-protocols 自宿主憲法（沒 `design_source` block）。fixture 模式在 PROVIDER-PARITY-E2E.md §3 的「在目標專案目錄下」隱含要 cd 進 fixture，但執行者很容易忽略這條。
