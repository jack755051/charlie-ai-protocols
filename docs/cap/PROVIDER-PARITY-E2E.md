# Provider Parity E2E Checklist

> 把 Codex / Claude 真實 `cap workflow run` 從「人工觀察」轉為「可重跑、可審計、可比對」的正式驗收程序。本文件是 release 前的 gate 之一，也是 supervisor 跨 provider 表現對等性的依據。

---

## 1. 適用情境

跑下列任一情境後，必須照本 checklist 驗收：

- 重大 schema / capability 變更後（如 v0.21.x 任何 minor / patch）
- 切換 default CLI（`CAP_DEFAULT_AGENT_CLI`）前
- Provider SDK 升級後（claude-cli、codex-cli）
- 評估「Claude vs Codex 行為差異」時

---

## 2. 受測 workflow 與情境

最小受測組合（每個 provider 都跑一次，共 2 次）：

| Provider | Workflow | Prompt | 預期 goal_stage |
|---|---|---|---|
| Claude | `project-spec-pipeline` | 「針對 token monitor 產出最小規格，不實作」 | `formal_specification` |
| Codex | `project-spec-pipeline` | 同上 | 同上 |

擴充受測組合（推薦但非必跑）：

| Provider | Workflow | Prompt 例 |
|---|---|---|
| Claude | `project-constitution` | 「為 stt pipeline 建立憲章」 |
| Codex | `project-constitution-reconcile` | （在已有憲章專案內跑 addendum） |

---

## 3. 跑法

```bash
# 在目標專案目錄下
cd /path/to/your-project

# Claude 路徑
cap workflow run --cli claude --design-package <name> project-spec-pipeline "<prompt>"

# Codex 路徑（在另一個 sandbox 或乾淨 run dir）
cap workflow run --cli codex --design-package <name> project-spec-pipeline "<prompt>"
```

**注意**：
- 兩次 run 的 `<prompt>` 必須相同，方便比對輸出形狀
- `--design-package <name>` 對齊憲法的 `design_source.package`
- 若無 design source，省略 `--design-package` 或加 `--no-design`

---

## 4. 驗收 checklist

每次跑完，逐項對照 run 輸出目錄（`~/.cap/projects/<project_id>/reports/workflows/<workflow_id>/run_<timestamp>_<id>/`）。

### 4.1 流程完整性

- [ ] **Phase 1–N 全部 completed**（spec-pipeline 是 16 phase；implementation 15；qa 9）
- [ ] `run-summary.md` 存在且 `result.md` 顯示成功
- [ ] `agent-sessions.json` 存在
- [ ] `workflow.log` 存在且不含 fatal Python traceback
- [ ] `runtime-state.json` 反映 final state

### 4.2 Type B Task Constitution

- [ ] `~/.cap/projects/<id>/constitutions/<task_id>.json` 已寫入
- [ ] JSON 含 8 個固定欄位：`task_id` / `project_id` / `source_request` / `goal` / `goal_stage` / `success_criteria` / `non_goals` / `execution_plan`
- [ ] `goal_stage` 等於使用者意圖對應的階段（formal_specification / implementation_and_verification 等）
- [ ] `execution_plan` 為非空 array；每個 entry 有 `step_id` 與 `capability`
- [ ] **沒有別名**：不應出現 `task_summary` / `user_intent_excerpt` / `target_capability` 等舊形狀（v0.21.1+ 嚴格 schema）

### 4.3 Type C Handoff Tickets

- [ ] `~/.cap/projects/<id>/handoffs/` 為每個 AI step 各存一份 ticket
- [ ] spec-pipeline 應有：`prd.ticket.json` / `tech_plan.ticket.json` / `ba.ticket.json` / `dba_api.ticket.json` / `ui.ticket.json` / `spec_audit.ticket.json`
- [ ] 每張 ticket schema 通過 `engine/step_runtime.py validate-jsonschema <ticket> schemas/handoff-ticket.schema.yaml`
- [ ] `ticket_id` 格式為 `<task_id>-<step_id>-<seq>`

### 4.4 Type D Handoff Summaries

- [ ] 每個 AI step 在 run dir 留下對應的 `*-<step_id>.handoff.md`
- [ ] 含 YAML frontmatter（`agent_id` / `step_id` / `task_id` / `result` / `output_paths`）
- [ ] body 含 `task_summary` / `key_decisions` / `downstream_notes` 三段以上
- [ ] downstream step 的輸入 context 中可讀到 upstream summary path

### 4.5 Design Source

- [ ] 若憲法有 `design_source` block：`docs/design/source-summary.md` / `source-tree.txt` / `design-source.yaml` / `.source-hash.txt` 都存在
- [ ] design-source.yaml 的 `sha256` 欄位是 64 字元 hex
- [ ] UI step 的 ticket 或 summary 引用 `docs/design/source-summary.md`，不直接引用 raw package（summary-first 驗收）

### 4.6 Spec layer artifacts

- [ ] PRD（spec-pipeline）：`<run_dir>/<phase>-prd.md` 存在
- [ ] TechPlan：`<run_dir>/<phase>-tech_plan.md` 存在
- [ ] BA：`<run_dir>/<phase>-ba.md` 存在
- [ ] Schema SSOT：`<run_dir>/.../database/<module>_schema_v<ver>.md` 存在
- [ ] API Spec：`<run_dir>/<module>_API_v<ver>.md` 存在
- [ ] UI Spec + 設計資產：`<run_dir>/design/` 至少 4 個檔（UI Spec / Tokens / Screens / Prototype）
- [ ] Spec audit report：`<run_dir>/spec_audit.md` 存在
- [ ] Archive：`<run_dir>/_archive.md` 存在

### 4.7 Provider Parity

- [ ] **同 prompt 在 Claude 與 Codex 兩條 run 都跑到相同的 final phase**（不要求完全相同的內容）
- [ ] 兩條 run 的 `task_constitution.json` 都有相同的 8 個固定欄位（內容可以不同）
- [ ] 兩條 run 的 `goal_stage` 一致
- [ ] 兩條 run 的 `execution_plan` step_id / capability 列表結構一致
- [ ] 兩條 run 都產生相同數量的 Type C handoff tickets（每個 AI step 各一張）

---

## 5. 自動化部分：`scripts/workflows/provider-parity-check.sh`

只做 artifact 存在性 + schema validation + Type B 嚴格欄位檢查；**不呼叫 AI**、不比較內容語意。

```bash
bash scripts/workflows/provider-parity-check.sh \
  --run-dir ~/.cap/projects/<id>/reports/workflows/project-spec-pipeline/run_xxx \
  --task-id <task_id> \
  --project-id <project_id>
```

退出碼：
- `0`：全部 checklist §4.1–§4.6 通過
- `1`：至少一項缺漏（stderr 列出哪一項）

§4.7 Provider Parity 跨 run 對比由人工執行（自動化會引入語意比較複雜度，先擱置）。

---

## 6. 失敗時的處理

| 觀察到的失敗 | 第一步診斷 | 第二步行動 |
|---|---|---|
| Phase 2 persist 失敗 `MISSING_REQUIRED:goal` | 看 `<phase 1>` 的 draft md 內 JSON 形狀 | 是別名問題就回頭看 supervisor §2.5；不是的話檢查 prompt 是否要求模糊 |
| design source 解析失敗 | 看 `engine/step_runtime.py:_design_source_path` 三段式 | 檢查憲法 `design_source` 完整性、`~/.cap/designs/` 內容 |
| Phase N 卡 timeout | 看 `workflow.log` 該 phase 的 stderr | 提高該 step 的 `timeout_seconds` 或拆分任務 |
| Codex / Claude 行為發散 | 比對兩邊的 task_constitution.json 欄位差 | 收緊 `agent-skills/01-supervisor-agent.md` §2.5；下個 release 移除對應 alias |

---

## 7. 與 smoke 套件的關係

| 層次 | 入口 | 範圍 |
|---|---|---|
| **Unit smoke** | `tests/scripts/test-*.sh`（個別） | 單一 shell executor 行為 |
| **Deterministic e2e** | `tests/e2e/test-*.sh`（個別） | shell + workflow YAML 鏈路無 AI |
| **smoke-per-stage** | `bash scripts/workflows/smoke-per-stage.sh` | 上述 + binding gate（10 step / 136 assertions） |
| **Provider parity e2e**（本文件） | `cap workflow run` + `provider-parity-check.sh` | 真實 AI 執行 + artifact 驗收 |

前三層在 CI / 開發機都能 hermetic 跑；本層必須真實 AI runtime（claude-cli 或 codex-cli），通常在 release 前手動 + 自動 hybrid 執行。

---

## 8. Release Gate

打 minor / major tag（v0.X.0）前，本 checklist 必須在 Claude + Codex 至少一條 workflow 上跑通並記錄結果（建議貼進 release notes annexture 或 PR description）。Patch tag（v0.X.Y）視變更性質決定，純文件 / 純 shell-only 改動可以略過。
