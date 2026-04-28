# Constitution-Driven Execution Protocol (Mode C)

> 本文件定義「從使用者需求出發，動態建立任務憲章、產出執行計畫、逐步 spawn 聚焦型 sub-agent 完成工作並保存一切」的完整執行協議。
> 本協議繼承 `agent-skills/00-core-protocol.md` 的所有行為準則，並受 `policies/workflow-constitution.md` 的編排鐵律約束。

---

## 1. 定位與三模式路由

CAP 支援三種執行模式。本文件定義 Mode C。

| Mode | 觸發情境 | 流程特徵 | 成本 |
|---|---|---|---|
| **A — Ad-hoc Skill** | 單點任務、快速問答 | 無結構，直接回應 | 最低 |
| **B — Known Workflow** | `cap workflow run <id>` | 固定步驟、已知流程 | 固定 |
| **C — Constitution-Driven** | 多步驟、未知流程、需規劃 | 動態建 constitution → 計畫 → sub-agents | 按需擴展 |

### 1.1 Mode C 觸發條件

符合以下任一條件時，應進入 Mode C：

- 使用者明確要求任務規劃或建立憲章（「幫我規劃」「建立任務」「新專案」）
- 任務涉及多步驟、多角色、有依賴關係的交付
- 無現成 workflow 模板可直接套用
- 使用者透過 `cap workflow run-task` 或 `cap workflow compile` 進入

### 1.2 Mode C 不適用的情境

- 單一 skill 可完成的任務（改一行 code、跑一次 commit）→ Mode A
- 已有定義好的 workflow（version-control-private、readme-to-devops）→ Mode B
- 變動不超過 20 行且不涉及多角色 → Mode A

---

## 2. Phase 1：建立 Task Constitution 與執行計畫

### 2.1 讀取專案上下文

1. 若專案根目錄存在 `.cap.constitution.yaml` → 讀取 `inherits`、`allowed_agents`、`allowed_capabilities`、`binding_policy`
2. 若不存在 → 以 `00-core-protocol.md` 為唯一行為基底，不限制可用 agent

### 2.2 推導 Task Constitution

根據使用者需求，推導以下結構（對齊 `schemas/task-constitution.schema.yaml`）：

```yaml
task_id: task_{hash}
goal: 使用者原始需求
goal_stage: informal_planning | formal_specification | implementation_preparation | implementation_and_verification
risk_profile: low | medium | high | unknown
inferred_context:
  need_ui: boolean
  need_persistence: boolean
  need_api_contract: boolean
  planning_only: boolean
  unknown_domains: []
  requested_deliverables: []
success_criteria: [...]
constraints: [...]
non_goals: [...]
stop_conditions: [...]
```

**推導邏輯**（對齊 `engine/task_scoped_compiler.py`）：

- 偵測到「不要直接實作」「先規劃」「初步評估」→ `goal_stage: informal_planning`
- 偵測到 UI / web / frontend / 畫面 / 介面 → `need_ui: true`
- 偵測到 db / database / 儲存 / cache → `need_persistence: true`
- 偵測到 api / service / 串接 / 監控，或 `need_persistence` → `need_api_contract: true`
- 偵測到 rust / swift / kotlin / go → `unknown_domains`，`risk_profile: unknown`
- 偵測到「實作」「開發」「部署」「完成功能」→ `goal_stage: implementation_and_verification`

### 2.3 產出 Capability Graph 與 Agent Mapping

從 constitution 推導需要的 capability，建立依賴順序：

```
[informal_planning 預設上限]
  prd → tech_plan → archive

[formal_specification 展開]
  prd → tech_plan → ba → dba_api? → ui? → spec_audit → archive

[implementation_and_verification 全鏈]
  ...formal_specification... → frontend? → backend? → structure_audit → qa → devops
```

每個 capability 對應一個 agent-skill（透過 `schemas/capabilities.yaml` 的 `default_agent` 查詢）。

### 2.4 輸出執行計畫並等待確認

必須輸出結構化計畫，**等使用者確認後才能進入 Phase 2**：

```
[Task Constitution]
  Goal:       用 Tauri 做個 AI 額度監控小工具
  Stage:      informal_planning
  Risk:       unknown (Rust/Tauri)
  Domains:    [rust]

[Execution Plan]
  Step 1. prd          → 01-supervisor   — define goal and scope
  Step 2. tech_plan    → 02-techlead     — technical direction & risk
  Step 3. archive      → 99-logger       — archive decisions

[Governance]
  watcher: final_only
  logger:  milestone_log
  budget:  3 sub-agent sessions

[Cost Estimate]
  ~3 sub-agent invocations × ~3K tokens each ≈ 9K tokens

確認執行？
```

**遵守 workflow-constitution §4.1**：`informal_planning` 階段預設上限為 `prd + tech_plan`，不得自動展開 BA / DBA / UI / QA。

---

## 3. Phase 2：Sub-Agent 執行

### 3.1 Sub-Agent Prompt 模板

每個 sub-agent 只接收**聚焦的最小上下文**，不載入全部 agent-skills。

```
┌─────────────────────────────────────────────┐
│ Section A — 行為基底（~500 tokens）           │
│ 從 00-core-protocol.md 精簡提取              │
├─────────────────────────────────────────────┤
│ Section B — 角色技能（~1.5-2.5K tokens）      │
│ 對應的 agent-skill.md 完整內容               │
├─────────────────────────────────────────────┤
│ Section C — 任務上下文（~300-500 tokens）     │
│ 上游交接摘要 + 本步驟目標與驗收條件           │
├─────────────────────────────────────────────┤
│ Section D — 限制與產出格式（~200 tokens）     │
│ goal_stage 限制 + 輸出路徑 + 交接格式        │
└─────────────────────────────────────────────┘
每個 sub-agent 總計 ≈ 2.5-3.5K tokens
```

#### Section A：行為基底（精簡版 00）

以下為 sub-agent 必須遵守的最小行為集，從 `00-core-protocol.md` 提取：

```markdown
## 行為準則
- 所有對話使用繁體中文，專有名詞保留原文。
- 動手前列出 Context / Action / Impact 簡述。
- 禁止破壞性操作（git reset --hard、刪除未確認檔案）。
- 禁止越權：只做本角色職責內的事。
- 禁止修改 charlie-ai-protocols 來源檔。
- 完成前進行自我反思，只輸出結論式摘要。
```

#### Section B：角色技能

完整嵌入對應的 `agent-skills/{id}-{role}-agent.md`。不做裁剪，確保角色邊界與方法論完整。

#### Section C：任務上下文

```markdown
## 本次任務
- task_id: {task_id}
- 當前步驟：{step_id} — {step_name}
- 步驟目標：{step_objective}
- 上游交接摘要：
  {upstream_handoff_summary}
- 驗收條件（done_when）：
  {done_when_list}
```

**遵守 workflow-constitution §4.3 摘要傳遞原則**：上游交接摘要不超過 500 字。除非本步驟是 audit 類（需全文），否則不傳完整上游 artifact。

#### Section D：限制與產出格式

```markdown
## 限制
- goal_stage: {goal_stage}
- 本階段禁止產出：{stage_prohibited_artifacts}
- stop_conditions: {stop_conditions}

## 產出要求
1. 完整產出（full artifact）：寫入或輸出完整內容
2. 交接摘要（handoff summary）：不超過 500 字，格式如下：
   - agent_id: {agent_id}
   - task_summary: [一句話]
   - output_paths: [路徑清單]
   - result: 成功 | 失敗 | 待確認
   - key_decisions: [關鍵決策摘要]
   - downstream_notes: [下游需注意事項]
```

### 3.2 執行迴圈

對執行計畫中的每個步驟，依序執行：

```
for each step in execution_plan:
  1. 組裝 sub-agent prompt（Section A + B + C + D）
  2. Spawn sub-agent
     - Claude Code: 使用 Agent tool
     - CLI: 使用 cap agent 或 CrewAI
  3. 接收 sub-agent 產出
  4. 驗證 done_when
     - 全部通過 → 提取 handoff summary，進入下一步
     - 部分未通過 → 重試一次並補充指引
     - 仍未通過 → halt，向使用者回報
  5. 更新 artifact ledger：
     - step_id
     - artifact_name
     - artifact_path
     - handoff_summary
     - status: completed | failed | skipped
```

### 3.3 失敗處理

| 失敗類型 | 動作 |
|---|---|
| 規格不足（sub-agent 回報 `needs_data`） | 暫停，向使用者要求補充 |
| 產出未通過 done_when | 重試一次，附上具體缺漏指引 |
| 重試仍失敗 | halt，輸出已完成步驟 + 失敗診斷 |
| 預算超限（步驟數超過 budget） | 停止，輸出當前成果 |
| stop_condition 觸發 | 停止，不視為失敗 |

**遵守 workflow-constitution §4.2**：目標達成即停止，不因「還有下一步」而繼續。

### 3.4 Governance Checkpoint

依 constitution 的 governance 設定，在指定步驟執行品質檢查：

- `watcher_mode: final_only` → 最後一步完成後，執行一次結構一致性檢查
- `watcher_mode: milestone_gate` → 在 `watcher_checkpoints` 指定的步驟後執行稽核
- 稽核參照 `90-watcher-agent.md` 的檢查清單，但只檢查本次 goal_stage 相關的項目

---

## 4. Phase 3：持久化與結案

### 4.1 保存 Task Constitution

```
~/.cap/projects/<project_id>/constitutions/<task_id>.json
```

內容為 Phase 1 產出的完整 task constitution。

### 4.2 保存 Artifact

每個步驟的完整產出：

```
~/.cap/projects/<project_id>/reports/workflows/<task_id>/
├── <step_id>.md          (full artifact)
├── <step_id>.handoff.md  (handoff summary)
└── ...
```

### 4.3 保存 Execution Trace

```
~/.cap/projects/<project_id>/traces/<task_id>.jsonl
```

每行一筆 event：

```jsonl
{"event":"step_start","step_id":"prd","ts":"..."}
{"event":"step_complete","step_id":"prd","status":"completed","ts":"..."}
{"event":"step_start","step_id":"tech_plan","ts":"..."}
...
```

### 4.4 輸出結案摘要

```
[Mode C — Task Complete]
  task_id:         task_a1b2c3d4e5
  goal:            用 Tauri 做個 AI 額度監控小工具
  goal_stage:      informal_planning
  steps_completed: 3/3
  artifacts:
    - constitutions/task_a1b2c3d4e5.json
    - reports/workflows/task_a1b2c3d4e5/prd.md
    - reports/workflows/task_a1b2c3d4e5/tech_plan.md
    - reports/workflows/task_a1b2c3d4e5/archive.md
  governance:
    watcher: final_only (passed)
    logger:  milestone_log
  result: 成功
```

若任務涉及正式產出（如 spec、schema、architecture doc），應提示使用者透過 `cap promote` 將成果從 `.cap` 升級到 repo。

---

## 5. Token 成本模型

### 5.1 每個 Sub-Agent 的成本

| 組件 | Token 估計 | 說明 |
|---|---|---|
| Section A（行為基底） | ~500 | 精簡版 00，固定 |
| Section B（角色技能） | ~1,500–2,500 | 單份 agent-skill，依角色而異 |
| Section C（任務上下文） | ~300–500 | 上游 handoff summary |
| Section D（限制與產出） | ~200 | 固定模板 |
| **合計** | **~2,500–3,700** | — |

### 5.2 與其他模式的比較

| 模式 | 每次互動的 context 成本 | 說明 |
|---|---|---|
| Mode A | ~3K（常駐 00 + git-workflow） | 最小，直接回應 |
| Mode B | ~4K（常駐 + workflow 定義） | 固定開銷 |
| Mode C 主控 | ~3K（常駐 + constitution） | 負責建計畫與調度 |
| Mode C 每個 sub-agent | ~3K（精簡 00 + 1 份 skill + handoff） | 只載入所需 |
| **Mode C 總計（3 步驟）** | **~12K** | 主控 3K + sub-agents 9K |

對比：若每個 sub-agent 都載入全部 17 份 agent-skills，同樣 3 步驟需要 ~80K+ tokens。

### 5.3 成本控制手段

1. **Summary-first handoff**：下游只吃摘要，不吃全文
2. **單 skill 載入**：每個 sub-agent 只拿一份 agent-skill
3. **Stage-appropriate 限制**：informal_planning 不展開重型資產
4. **Budget governance**：步驟數超限即停止
5. **停止即成功**：目標達成不繼續堆疊

---

## 6. 跨 Runtime 適配

本協議不綁定特定 AI runtime。各環境的 sub-agent spawn 方式：

| Runtime | Spawn 方式 | 備註 |
|---|---|---|
| **Claude Code** | `Agent` tool，prompt 參數帶入模板 | sub-agent 天然隔離 context |
| **Codex CLI** | `cap agent <role> "<prompt>"` | 透過 cap-agent.sh 轉接 |
| **CrewAI** | `factory.py` 建立 Agent，`Crew.kickoff()` 執行 | 原生多 agent 支援 |
| **未來 runtime** | 遵守 `cap-execution-model.md §3` 的 agent session 抽象 | provider adapter 模式 |

---

## 7. 與現有體系的關係

| 現有文件 | 與本協議的關係 |
|---|---|
| `00-core-protocol.md` | 本協議繼承其所有行為準則；Section A 是其精簡提取 |
| `01-supervisor-agent.md` | Mode C 不依賴 01 的硬編碼預設；01 是 Mode B 全棧交付的特化 supervisor |
| `workflow-constitution.md` | 本協議的 Phase 2 受其所有鐵律約束（最小充分、摘要傳遞、停止即成功） |
| `task-constitution.schema.yaml` | Phase 1 的 constitution 輸出對齊此 schema |
| `project-constitution.schema.yaml` | 若專案有 `.cap.constitution.yaml`，Phase 1 會讀取其治理邊界 |
| `cap-execution-model.md` | 本協議的 lifecycle 與 storage 遵守其分層模型 |
| `cap-storage.md` | Phase 3 的持久化路徑遵守其儲存規則 |
| `task_scoped_compiler.py` | Phase 1 的推導邏輯與其對齊；CLI 路徑直接調用此模組 |

---

## 8. 違規訊號

以下情況應視為違反本協議：

1. Sub-agent 被載入超過一份 agent-skill
2. 下游 sub-agent 收到完整上游 artifact 而非 handoff summary（audit 類除外）
3. `informal_planning` 階段自動展開 BA / DBA / UI / QA
4. 使用者未確認即進入 Phase 2
5. 步驟失敗後未經回報即跳過
6. 產出未保存到 `.cap` storage
7. 結案摘要缺少 task_id、goal_stage 或 steps_completed
