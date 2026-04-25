# Project Constitution Workflow Memo

本備忘錄整理「從一個想法建立 repo」時，CAP 應如何產生 constitution、啟動一次性 agent session、保存結果並回收 runtime state。

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

### Phase 2: Runtime

1. `cap workflow run project-constitution "<idea>"`
2. 產生 constitution markdown/json
3. `cap workflow compile --from-constitution <constitution>`
4. 產生一次性 execution plan

### Phase 3: Session Lifecycle

1. 建立 `agent-sessions.json`
2. session 狀態：`planned` → `running` → `completed|failed|cancelled` → `recycled`
3. 保留 constitution / result / promoted artifacts
4. 清理 scratch / temp / raw logs

## 設計決策

- 不把 sub agent 綁死為 Claude 或 Codex 專屬功能。
- 不讓「建立憲章」成為每個小任務的必經流程，避免 callback 地獄。
- constitution workflow 只產生 B，不直接開發 repo。
- 真正開發由 B 編譯出的 task workflow 負責。
- 重複、可驗證的步驟優先 shell；語意不明才 AI；高風險直接 halt。
