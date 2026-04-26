# CAP Platform Goal

> 本文件定義 CAP 的產品目標、目標執行模型、目前完成度與後續重構方向。

## 1. 目標定位

CAP 的目標不是單一 agent prompt 集合，而是一個本機 AI workflow runtime 平台。

使用者安裝 CAP 後，平台應提供：

- 內建 agent skills
- 內建 workflow templates
- capability contracts
- provider adapters
- project constitution 產生與保存
- task workflow compile / bind / run
- agent session lifecycle 紀錄
- 本機 runtime artifact storage

CAP 應讓使用者在登入 Codex CLI 與 Claude Code CLI 後，可以直接在任一資料夾或 repo 中使用基礎 agent skills 與 workflows，並把執行成果保存到本機 CAP storage。

## 2. 使用者目標流程

預期使用流程如下：

```text
install CAP
  -> login Codex / Claude Code CLI
  -> use base agent-skills and workflow templates
  -> run CAP inside a folder or repo
  -> generate Project Constitution
  -> Supervisor reads user prompt and repo context
  -> Supervisor decides required capabilities and agent roles
  -> CAP compiles task workflow
  -> CAP binds workflow steps to agent skills / provider CLI
  -> CAP creates short-lived agent sessions
  -> agent sessions produce artifacts and handoff summaries
  -> CAP archives constitution, workflow, binding, sessions and result report
```

CAP 的關鍵價值是讓「AI 多代理協作」從臨時口頭指令，升級成可治理、可追蹤、可重複執行的 runtime。

## 3. 儲存模型

CAP 應明確區分正式來源與 runtime 產物。

```text
Project repo
├── .cap.project.yaml
├── .cap.constitution.yaml
├── .cap.skills.yaml
├── workflows/ or schemas/workflows/
└── docs/

~/.cap/projects/<project_id>/
├── constitutions/
├── compiled-workflows/
├── bindings/
├── reports/
├── traces/
├── logs/
├── drafts/
├── handoffs/
├── cache/
└── sessions/
```

原則：

- repo 放 source of truth
- `~/.cap/projects/<project_id>/` 放 runtime state
- Project Constitution 的正式版本應屬於 repo
- 單次任務推導出的 task constitution / compiled workflow / binding snapshot / run output 應屬於 CAP storage
- 成熟且需長期維護的 custom workflow 或 skill，才應 promote 回 repo 或 shared registry

## 4. Constitution 分層

CAP 應拆分兩種 constitution。

### Project Constitution

Project Constitution 是某個 repo 的長期治理規則。

應包含：

- project goal
- project constraints
- source-of-truth paths
- allowed agents
- allowed capabilities
- workflow source policy
- binding policy
- artifact policy
- executor policy
- security / risk stop conditions

建立方式：

```bash
cap workflow run project-constitution "這個 repo 是一個..."
```

或由更高階入口包裝：

```bash
cap project constitution "這個 repo 是一個..."
```

### Task Constitution

Task Constitution 是單次 prompt 的執行憲法。

應包含：

- source request
- inferred goal stage
- success criteria
- non-goals
- required capabilities
- risk profile
- unresolved policy
- stop conditions
- expected artifacts

它應由 Project Constitution、user prompt 與 repo context 推導而來。

## 5. Supervisor Orchestration

Supervisor 是 CAP 的編排決策者，不應只是一般 workflow step。

Supervisor 應負責：

- 讀取 Project Constitution
- 讀取 user prompt
- 讀取 repo context
- 判斷任務類型與風險
- 決定需要哪些 capabilities
- 決定應啟動哪些 agent roles
- 產出 structured task constitution
- 產出 capability graph
- 產出 compiled workflow draft
- 決定哪些步驟需要 Watcher / Security / QA / Logger

Supervisor 的輸出不得只靠自然語言。正式派工前必須落成 JSON / YAML artifact，供 runtime 驗證與追蹤。

## 6. Agent Session Model

CAP 的 sub-agent 不應直接等同於 Codex 或 Claude 的原生能力。

CAP 應定義自己的抽象：

```text
Agent Session = CAP runtime 根據 role / capability / prompt / inputs 啟動的一次性 worker session
```

每個 agent session 至少應紀錄：

- `session_id`
- `run_id`
- `workflow_id`
- `step_id`
- `capability`
- `agent_alias`
- `prompt_file`
- `provider`
- `provider_cli`
- `input_artifacts`
- `output_artifacts`
- `handoff_path`
- `status`
- `started_at`
- `completed_at`
- `failure_reason`

Provider adapter 可以對應：

- Codex: `codex exec`
- Claude: `claude -p`
- CrewAI: future graph / crew runtime
- LangGraph or other runtime: future backend

workflow 不應綁死 provider 細節，只宣告 capability、agent role、inputs、outputs 與 lifecycle。

## 7. 目標 Runtime Lifecycle

一次完整 CAP run 的 lifecycle 應為：

```text
intake
  -> load project context
  -> load Project Constitution
  -> supervisor orchestration
  -> task constitution
  -> capability graph
  -> compile workflow
  -> bind agents
  -> preflight
  -> create agent sessions
  -> execute steps
  -> validate artifacts
  -> archive result
  -> mark sessions recycled
```

CAP 應遵守：

```text
deterministic-first, AI-on-ambiguity, halt-on-risk
```

也就是：

- 可重複且低語意判斷的工作優先交給 shell / parser / deterministic scripts
- 語意判斷、規格推導、例外診斷與設計決策才交給 AI agent
- 遇到高風險、缺少必要輸入、binding 不完整或安全疑慮時 halt

## 8. 目前完成度

已完成或接近完成：

- 安裝流程會建立 `~/.cap/projects/`
- 基礎 agent skills 已存在
- workflow templates 已存在
- `.cap.skills.yaml` 可作為 skill registry
- `RuntimeBinder` 可將 capability 綁定到 agent skill / CLI
- `cap workflow plan / bind / run` 已可使用 bound plan
- `cap workflow compile / run-task` 已可從 prompt 產生 task-scoped workflow
- `cap-workflow-exec.sh` 已能逐 step 呼叫 Codex / Claude CLI
- workflow output 已能寫入 CAP storage
- runtime state、artifact index、handoff summary 已有雛形

尚未完成：

- Project Constitution 產生還未完全由 `project-constitution.yaml` + Supervisor agent 驅動
- `cap workflow constitution` 目前偏 task constitution，不是完整 project constitution workflow runner
- Supervisor 尚未真正成為 structured orchestration layer
- sub-agent 目前只是 step-level CLI invocation，尚未有正式 Agent Session Ledger
- `agent-sessions.json` 尚未落地
- background / detached run 尚未實作
- Project Constitution schema 尚未正式化
- repo-specific workflow / skill source resolver 尚未完整
- promote / publish 流程尚未完整閉環

## 9. 目標架構調整

為了達成平台目標，CAP 應優先調整以下部分：

1. 補正式 Project Constitution schema
2. 讓 `project-constitution.yaml` 真的透過 Supervisor agent 產出 Project Constitution Markdown / JSON
3. 將 `cap workflow constitution` 的語意改清楚，避免和 task constitution 混用
4. 建立 Supervisor structured orchestration output
5. 將 current step execution 升級為 Agent Session Runner
6. 新增 `agent-sessions.json`
7. 將 run result 明確歸檔為 `result.md`
8. 補 project initializer
9. 補 repo-specific source resolver
10. 補 promote / publish workflow

## 10. 非目標

短期內 CAP 不應優先做：

- Web UI
- 遠端 SaaS 控制台
- 複雜多人即時協作
- 完整 marketplace 商業分發
- 綁死某單一 provider 的 sub-agent 能力

短期重點應放在本機 CLI runtime 的可追蹤性、可重複性與治理閉環。
