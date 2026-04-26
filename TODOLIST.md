# CAP Platform TODO List

更新日期：2026-04-26

## 目標

CAP 的目標是一個本機 AI workflow runtime 平台，而不是單純的 agent prompt / workflow template 倉庫。

安裝 CAP 並登入 Codex / Claude Code CLI 後，使用者應能在任一資料夾或 repo 中使用基礎 agent skills 與 workflows。CAP 會為該 project 建立 `~/.cap/projects/<project_id>/`，保存 constitution、compiled workflows、bindings、agent sessions、handoffs、reports、traces 與執行結果。

完整目標文檔見 [docs/CAP-PLATFORM-GOAL.md](docs/CAP-PLATFORM-GOAL.md)。

## 核心原則

- CAP 是平台層，負責 runtime、binding、compile、promote、registry adapter 與 session lifecycle。
- agent-skill 是角色能力與邊界的基底。
- workflow 是依需求組裝 capability 的編排模板。
- Project Constitution 是 repo 長期治理規則。
- Task Constitution 是單次 prompt 的執行憲法。
- repo 放 source of truth。
- `~/.cap/projects/<project_id>/` 放 runtime state。
- sub-agent 應抽象為 CAP Agent Session，不綁死 Codex 或 Claude 原生能力。
- runtime 遵守 deterministic-first、AI-on-ambiguity、halt-on-risk。

## 目前完成狀態

### 已完成

- [x] 基礎 agent skills 已建立於 `docs/agent-skills/`
- [x] 全域 core protocol 已建立
- [x] workflow templates 已建立於 `schemas/workflows/`
- [x] capability contract 已建立於 `schemas/capabilities.yaml`
- [x] `.cap.skills.yaml` 已可作為 workflow binding 的優先輸入
- [x] `.cap.agents.json` legacy adapter 已保留相容
- [x] `RuntimeBinder` 已可將 workflow step 綁定到 agent skill / provider CLI
- [x] `ProjectContextLoader` 已可讀取 repo 級 project context
- [x] `TaskScopedWorkflowCompiler` 已可從 prompt 推導 task constitution、capability graph 與 compiled workflow
- [x] `cap workflow plan / bind / run` 已共用 bound execution plan
- [x] `cap workflow compile / run-task` 已可產生 task-scoped workflow bundle
- [x] `cap-workflow-exec.sh` 已可前景逐 step 呼叫 `codex exec` 或 `claude -p`
- [x] workflow output 已寫入 `~/.cap/projects/<project_id>/reports/workflows/`
- [x] artifact index、handoff summary、runtime-state 已有雛形
- [x] CAP storage policy 已文件化

### 尚未完成

- [ ] Project Constitution schema 尚未正式化
- [ ] `project-constitution.yaml` 尚未成為完整 Project Constitution runner
- [ ] `cap workflow constitution` 目前較接近 task constitution 產生器，語意需拆清楚
- [ ] Supervisor 尚未真正負責 structured orchestration
- [ ] Supervisor 尚未輸出可驗證的 task constitution / capability graph / compiled workflow draft
- [ ] sub-agent 尚未升級為 CAP Agent Session
- [ ] `agent-sessions.json` 尚未落地
- [ ] agent session lifecycle 尚未紀錄 `created / running / completed / failed / recycled`
- [ ] detached / background workflow run 尚未實作
- [ ] repo-specific workflow / skill source resolver 尚未完整
- [ ] promote / publish 流程尚未閉環

## 近期重構路線

### Milestone 1: Project Constitution Runner

- [ ] 定義 `schemas/project-constitution.schema.yaml`
- [ ] 明確區分 Project Constitution 與 Task Constitution
- [ ] 調整 `schemas/workflows/project-constitution.yaml` 的輸出契約
- [ ] 讓 Project Constitution workflow 產出 Markdown 與 JSON
- [ ] 對 Project Constitution JSON 做 schema validation
- [ ] 將通過驗證的 Project Constitution snapshot 保存到 CAP storage
- [ ] 提供 promote 或 init 路徑，將正式 Project Constitution 寫回 repo

### Milestone 2: CLI 語意整理

- [ ] 決定 `cap workflow constitution` 是否保留為 task constitution 入口
- [ ] 新增或規劃 `cap project constitution "<prompt>"`
- [ ] 新增或規劃 `cap project init`
- [ ] 文件化 `constitution / compile / run-task / run` 的差異
- [ ] 更新 CLI help，避免 Project Constitution 與 Task Constitution 混用

### Milestone 3: Supervisor Structured Orchestration

- [ ] 定義 Supervisor orchestration output schema
- [ ] Supervisor 讀取 Project Constitution、user prompt、repo context
- [ ] Supervisor 產出 task constitution
- [ ] Supervisor 產出 capability graph
- [ ] Supervisor 產出 compiled workflow draft
- [ ] Supervisor 標註 Watcher / Security / QA / Logger checkpoint
- [ ] runtime 驗證 Supervisor 輸出，不接受純自然語言派工

### Milestone 4: Agent Session Ledger

- [ ] 定義 `schemas/agent-session.schema.yaml` 的 runtime 實例欄位
- [ ] 在每個 workflow step 前建立 `session_id`
- [ ] 記錄 `run_id / workflow_id / step_id / capability / agent_alias / prompt_file / provider_cli`
- [ ] 記錄 input artifact 與 output artifact
- [ ] 記錄 handoff path
- [ ] 記錄 status 與 failure reason
- [ ] 每次 run 產出 `agent-sessions.json`
- [ ] workflow 結束後將 session 標記為 `completed / failed / cancelled / recycled`

### Milestone 5: Result Report

- [ ] 每次 run 產出正式 `result.md`
- [ ] `result.md` 彙整 constitution、compiled workflow、binding、sessions、artifacts、failures
- [ ] 明確區分 `runtime-state.json` 與人類可讀 result report
- [ ] 補 final archive 規則，讓 Logger (99) 可接手整理結案摘要

### Milestone 6: Repo-specific Source Resolver

- [ ] 支援 repo-local workflow source roots
- [ ] 支援 repo-local skill registry
- [ ] 明確區分 builtin / project / shared skill source
- [ ] 套用 Project Constitution 的 allowed source roots
- [ ] binding report 顯示每個 step 使用的 source layer

### Milestone 7: Promote / Publish

- [ ] 定義 runtime artifact promote 回 repo 的規則
- [ ] 定義 project skill / workflow publish 到 shared registry 的規則
- [ ] 補 `cap promote` 文件與範例
- [ ] 避免 `.cap` runtime snapshot 被誤當正式 source of truth

### Milestone 8: Background Run

- [ ] 設計 detached run 的 process model
- [ ] 讓 `cap workflow run -d` 真正執行背景任務
- [ ] `cap workflow ps` 顯示 running / completed / failed
- [ ] `cap workflow inspect <run-id>` 顯示 session、artifact 與 failure 摘要

## 優先順序

1. Project Constitution schema 與 runner
2. CLI 語意整理
3. Supervisor structured orchestration
4. Agent Session Ledger
5. Result Report
6. Repo-specific source resolver
7. Promote / publish
8. Background run

## 風險與注意事項

- 不要把 `.cap` runtime snapshot 當成正式原文唯一來源。
- 不要讓 Supervisor 只輸出口頭派工，正式派工必須有 JSON / YAML artifact。
- 不要把 CAP Agent Session 綁死在 Codex 或 Claude 的原生 sub-agent 實作。
- 不要在 Project Constitution 尚未 schema 化前擴張太多 repo-specific workflow 行為。
- 不要優先做 Web UI；目前瓶頸在 runtime 可追蹤性與治理閉環。
