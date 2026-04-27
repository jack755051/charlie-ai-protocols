# Project Constitution Workflow Memo

本備忘錄整理「從一個想法建立 repo」時，CAP 應如何產生 constitution、啟動一次性 agent session、保存結果並回收 runtime state。

## 術語對照（避免混淆）

CAP repo 內有多個檔案名稱含 `constitution`，分屬不同層級。閱讀本備忘錄與 `schemas/workflows/project-constitution.yaml` 前，請先對照下表：

| # | 檔案 | 層級 | 是什麼 | 規範對象 |
|---|---|---|---|---|
| 1 | `docs/policies/workflow-constitution.md` | **元憲法** | runtime 跑 workflow 時的最高治理規則（phase 上限、summary-first handoff、artifact tiering、stop-when-goal-satisfied 等） | 所有 workflow（含 #2 自己） |
| 2 | `schemas/workflows/project-constitution.yaml` | **workflow 模板** | 一條具體的 workflow 定義，用來「產出 repo 級 Project Constitution 文件」 | 只是一條流程，本身受 #1 約束 |
| 3 | `schemas/project-constitution.schema.yaml` | **產物 schema** | 定義 Project Constitution JSON 該長怎樣（必填欄位、型別） | 約束 #2 step 的 output |
| 4 | `.cap.constitution.yaml` | **實例 Project Constitution** | 某個 repo 的具體治理憲法（CAP 自己這個 repo 的範例就在 root） | 約束該 repo 內所有 workflow 執行 |
| 5 | `schemas/task-constitution.schema.yaml` | **task 憲法 schema** | 定義單次 prompt 編譯產出的 task 憲法結構 | 約束 task 編譯產物 |
| 6 | `schemas/workflows/project-constitution-reconcile.yaml` | **reconcile workflow 模板** | 既有 Constitution + 補充 prompt 的單次收斂流程，用來產出修正版草案並覆寫保存 | 約束 #4 的後續修訂流程 |

關鍵關係：

- #1 規定「**所有 workflow** 都要遵守」——例如 phase 上限、summary-first、stop-when-goal-satisfied
- #2 是其中**一條 workflow**，自己也要遵守 #1（因此 #2 的 yaml 設 `goal_stage: informal_planning`，受 #1 §7 階段模型約束）
- #3 約束的是 #2 的產物
- #4 是某 repo 跑完 #2 後保存下來的實際結果（或人工撰寫的版本）
- #5 與 #4 不同：#4 是長期治理憲法、#5 是單次任務的執行憲法
- #6 是 #2 的補充流程：當初版資訊不完整時，先保留 #4 的最小 SSOT，再用補充 prompt 一次性收斂，不在 #4 內塞空白 addendum

> **不要把 #1 與 #2 看成同類**。#1 是「跑 workflow 的規則」、#2 是「一條跑出 constitution 的 workflow」。#2 的 workflow_id 維持為 `project-constitution`，但讀者應始終透過上表確認對應的是哪個層級。

## 情境

使用者只有一個想法，例如：

> 我要做一個 STT repo。

CAP 應支援：

```text
使用者想法
  ↓
A. project-constitution workflow
  ↓
B. Project Constitution / Task Constitution
  ↓
C. 一次性 agent sessions 執行 repo 建立
  ↓
D. Result report / handoff
  ↓
保存 B、D；回收 C
```

## 產物定義

- **B: Constitution**
  - 長期或中期規範。
  - 包含 project goal、使用者偏好、技術限制、executor policy、allowed agents、artifact storage policy。
  - 保存於 `.cap/projects/<project_id>/constitutions/`。

- **C: Agent sessions**
  - 一次性 worker，不是長期 agent 定義。
  - 由 CAP runtime 根據 capability / prompt / provider 啟動。
  - 可對應 Claude、Codex 或其他 provider adapter。

- **D: Result report**
  - 單次任務結案紀錄。
  - 包含完成內容、artifact paths、session lifecycle、阻塞與風險。
  - 保存於 `.cap/projects/<project_id>/reports/`。

## 開發順序

### Phase 1: 規格與模板

1. `docs/policies/cap-execution-model.md`
2. `docs/policies/workflow-executor-selection.md`
3. `schemas/agent-session.schema.yaml`
4. `schemas/workflows/project-constitution.yaml`
5. `schemas/workflows/project-constitution-reconcile.yaml`

### Phase 2: Runtime

1. `cap workflow run project-constitution "<idea>"`
2. 產生 constitution markdown/json
3. 若第一次資訊不足，另跑 `cap workflow run project-constitution-reconcile "<addendum>"`
4. `cap workflow compile --from-constitution <constitution>`
5. 產生一次性 execution plan

### Phase 3: Session Lifecycle

1. 建立 `agent-sessions.json`
2. session 狀態：`planned` → `running` → `completed|failed|cancelled` → `recycled`
3. 保留 constitution / result / promoted artifacts
4. 清理 scratch / temp / raw logs

## 設計決策

- 不把 sub agent 綁死為 Claude 或 Codex 專屬功能。
- 不讓「建立憲章」成為每個小任務的必經流程，避免 callback 地獄。
- constitution workflow 只產生 B，不直接開發 repo。
- 若 B 的初版資訊不足，補充內容應由 `project-constitution-reconcile` workflow 吸收，不要把 additional prompt 當成 constitution 本體的一部分。
- 真正開發由 B 編譯出的 task workflow 負責。
- 重複、可驗證的步驟優先 shell；語意不明才 AI；高風險直接 halt。
