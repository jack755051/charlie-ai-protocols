# CAP Complete Implementation Roadmap

> 本文件是 CAP 從目前「workflow runtime + agent skill registry 雛形」走到完整本機 AI workflow runtime 平台的開發備忘錄。
> 產品目標見 [PLATFORM-GOAL.md](PLATFORM-GOAL.md)。
> 尚未完成項目的可執行工程清單請參考 [MISSING-IMPLEMENTATION-CHECKLIST.md](MISSING-IMPLEMENTATION-CHECKLIST.md)。

## 1. 目標總圖

CAP 最終要支援以下完整鏈路：

```text
install CAP
  -> login Codex / Claude CLI
  -> run CAP inside any repo or folder
  -> initialize / resolve project storage
  -> generate or load Project Constitution
  -> Supervisor reads prompt + repo context + constitution
  -> Supervisor emits structured orchestration
  -> runtime creates Task Constitution
  -> runtime creates Capability Graph
  -> runtime compiles executable workflow
  -> runtime binds workflow to agent skills and provider adapters
  -> runtime creates CAP Agent Sessions
  -> provider adapters execute work
  -> runtime validates artifacts, handoffs and gates
  -> runtime writes result report and session ledger
  -> selected runtime artifacts may be promoted back to repo source of truth
```

核心原則：

- repo 放 source of truth
- `~/.cap/projects/<project_id>/` 放 runtime state
- Project Constitution 是 repo 長期治理憲法
- Task Constitution 是單次任務執行憲法
- CAP Agent Session 是 CAP 自己的 sub-agent 抽象，不等於 Codex / Claude 原生 subagent
- deterministic-first, AI-on-ambiguity, halt-on-risk

## 2. 目前基線

已完成或已落地雛形：

- 安裝流程建立 `~/.cap/projects/`
- 基礎 agent skills
- workflow templates
- capability contracts
- `.cap.skills.yaml` skill registry
- `.cap.agents.json` legacy adapter
- `RuntimeBinder`
- `ProjectContextLoader`
- `TaskScopedWorkflowCompiler`
- `cap workflow plan / bind / run`
- `cap workflow compile / run-task`
- foreground step executor
- artifact index / handoff summary / runtime-state
- `schemas/project-constitution.schema.yaml` draft
- `agent-sessions.json` executor-level ledger
- `result.md` 初版 run archive

主要缺口（含 v0.19.x 進度註記）：

- Project Constitution runner 尚未完整 — `project-constitution.yaml` workflow 已穩定，但 task-scoped runner（task constitution + execution_plan + per-step ticket）僅做到 deterministic shell + workflow YAML 層；engine `step_runtime` 自動 ticket emission hook 仍 deferred
- `cap workflow constitution` 與 Project Constitution 語意尚未拆乾淨
- Supervisor structured orchestration **v0.19.x 部分落地**：per-stage workflow（spec / implementation / qa）固化派工迴圈、Type C handoff ticket schema + emit shell executor、`policies/handoff-ticket-protocol.md` 規範非 supervisor sub-agent 的 ticket 讀寫；engine 自動 hook 與 sub-agent 端 e2e consumption 仍 deferred
- AgentSessionRunner 尚未抽象化
- Artifact validation / governance gates **v0.19.x 部分強化**：persist-task-constitution.sh 與 emit-handoff-ticket.sh 接入 `engine/step_runtime.py validate-jsonschema` 全 schema 驗證；watcher milestone gate 規範已寫入三條 per-stage workflow，但 runtime 自動觸發與 fail route_back_to 自動回流仍 deferred
- repo-specific source resolver 尚未完整
- promote / publish 閉環尚未完整
- detached / background runtime 尚未實作

未來可選的外部方法論包：

- `superpowers` 類型的方法論可在後續以「功能導向 workflow / capability pack」方式接入 CAP
- 原則是保留 CAP 的憲章、binding、runtime storage 與 capability contract，不直接把外部 skill pack 改寫成核心角色定義
- 可能的映射方向包括：`brainstorming`、`planning`、`execution`、`review`、`test-driven-development`
- 這一層應作為使用體驗與工作法的增強，而不是治理模型的替代品

## 3. Phase 1: Contracts Complete

目標：先把所有 runtime artifacts 的資料契約固定，避免後續 CLI 與 engine 實作互相漂移。

需要完成的 schema：

- [x] `schemas/project-constitution.schema.yaml`
- [x] `schemas/task-constitution.schema.yaml`
- [x] `schemas/agent-session.schema.yaml`
- [x] `schemas/capabilities.yaml`
- [ ] `schemas/capability-graph.schema.yaml`
- [ ] `schemas/compiled-workflow.schema.yaml`
- [ ] `schemas/binding-report.schema.yaml`
- [ ] `schemas/supervisor-orchestration.schema.yaml`
- [ ] `schemas/workflow-result.schema.yaml`
- [ ] `schemas/gate-result.schema.yaml`

每個 schema 都要定義：

- required fields
- enum values
- source / runtime ownership
- validation failure behavior
- forward-compatible version field

完成標準：

- runtime 產出的主要 JSON artifact 都有對應 schema
- schema parse test 通過
- schema 文件被 README / ARCHITECTURE / workflow docs 引用

## 4. Phase 2: Project Storage and Identity

目標：CAP 能穩定辨識目前 project，並建立一致的 local storage。

目標結構：

```text
~/.cap/projects/<project_id>/
├── constitutions/
├── compiled-workflows/
├── bindings/
├── reports/
│   └── workflows/<workflow_id>/<run_id>/
│       ├── artifact-index.md
│       ├── runtime-state.json
│       ├── agent-sessions.json
│       ├── result.md
│       └── workflow.log
├── traces/
├── logs/
├── drafts/
├── handoffs/
├── cache/
└── sessions/
```

需要完成：

- [x] `cap paths`
- [x] `.cap.project.yaml` 作為 project identity source
- [x] git root basename fallback
- [ ] 非 git folder 的 project id 策略
- [ ] project id collision 處理
- [ ] storage version / migration metadata
- [ ] storage health check

建議 CLI：

```bash
cap project status
cap project init
cap project paths
cap project doctor
```

## 5. Phase 3: Project Constitution Runner

目標：正式產生 repo 長期治理憲法，而不是只產生 task constitution。

完整流程：

```text
user prompt
  -> cap project constitution "<prompt>"
  -> load repo context
  -> run schemas/workflows/project-constitution.yaml
  -> Supervisor emits Markdown + JSON
  -> extract JSON
  -> validate by schemas/project-constitution.schema.yaml
  -> save snapshot to CAP storage
  -> optionally promote to .cap.constitution.yaml
```

需要完成：

- [ ] Project Constitution validator
- [ ] agent output JSON extraction
- [ ] markdown / JSON dual artifact materialization
- [ ] schema validation failure halt
- [ ] constitution snapshot versioning
- [ ] `cap project constitution`
- [ ] `cap project constitution --promote`
- [ ] `cap project constitution --dry-run`
- [ ] `cap project constitution --from-file`
- [ ] promote target selection: `.cap.constitution.yaml` or `docs/cap/constitution.md`

目標 snapshot：

```text
~/.cap/projects/<project_id>/constitutions/project/<stamp>/
├── project-constitution.md
├── project-constitution.json
├── validation.json
└── source-prompt.txt
```

完成標準：

- `project-constitution` workflow 綁定到 `supervisor`
- Supervisor 產出的 JSON 可被 schema 驗證
- valid snapshot 可保存
- invalid output 會 halt，不會被 promote

## 6. Phase 4: Supervisor Structured Orchestration

目標：Supervisor 根據 prompt、Project Constitution 與 repo context 決定任務如何被拆成 capabilities 與 agent sessions。

Supervisor 不得只輸出自然語言；正式派工前必須落成 JSON / YAML artifact。

目標輸出：

```yaml
task_constitution:
  task_id:
  source_request:
  goal:
  non_goals:
  success_criteria:
  risk_profile:
  stop_conditions:

capability_graph:
  nodes:
    - step_id:
      capability:
      required:
      depends_on:
      reason:
  edges:

governance:
  watcher_checkpoints:
  security_checkpoints:
  qa_checkpoints:
  logger_mode:

compile_hints:
  goal_stage:
  output_tier:
  input_mode:
  max_steps:
  fallback_policy:
```

需要完成：

- [ ] `SupervisorOrchestrator`
- [ ] supervisor prompt builder
- [ ] structured output parser
- [ ] orchestration schema validator
- [ ] invalid output retry / halt policy
- [ ] deterministic compiler fallback policy
- [ ] orchestration snapshot storage

建議 CLI：

```bash
cap task plan "<prompt>"
cap task compile "<prompt>"
cap task run "<prompt>"
```

## 7. Phase 5: Compiled Workflow and Binding Pipeline

目標：把 capability graph 轉成真正可執行的 workflow 與 bound plan。

完整流程：

```text
capability_graph
  -> compiled_workflow.yaml/json
  -> RuntimeBinder
  -> binding_report.json
  -> executable bound plan
```

需要完成：

- [ ] compiled workflow schema
- [ ] binding report schema
- [ ] compiled workflow normalization
- [ ] project / shared / builtin / legacy source priority
- [ ] allowed capability enforcement
- [ ] allowed workflow source root enforcement
- [ ] fallback policy enforcement
- [ ] unresolved handling
- [ ] preflight report
- [ ] dry-run inspection

Binding source priority:

```text
project .cap.skills.yaml
  -> project workflows / skills
  -> shared registry
  -> CAP builtin .cap.skills.yaml
  -> legacy .cap.agents.json adapter
```

## 8. Phase 6: AgentSessionRunner

目標：把目前 step-level CLI invocation 升級成 CAP 自己的 Agent Session runtime。

Lifecycle：

```text
planned
  -> created
  -> running
  -> completed | failed | blocked | cancelled
  -> recycled
```

每個 session 應保存：

- `session_id`
- `run_id`
- `workflow_id`
- `step_id`
- `capability`
- `agent_alias`
- `prompt_file`
- `provider`
- `provider_cli`
- `provider_native_session_id`
- `parent_session_id`
- `input_artifacts`
- `output_artifacts`
- `handoff_path`
- `prompt_snapshot_path`
- `prompt_hash`
- `started_at`
- `completed_at`
- `duration_seconds`
- `lifecycle`
- `result`
- `failure_reason`
- `recycle_policy`

需要完成：

- [ ] `AgentSessionRunner`
- [ ] `ProviderAdapter` interface
- [ ] `CodexAdapter`
- [ ] `ClaudeAdapter`
- [ ] `ShellAdapter`
- [ ] prompt snapshot
- [ ] provider stdout / stderr capture
- [ ] timeout / stall integration
- [ ] session recycle
- [ ] parent / child relation
- [ ] `cap session inspect`

重點：Codex / Claude 只是 provider adapter，不是 CAP agent session 的資料模型本身。

## 9. Phase 7: Artifact, Handoff and Validation

目標：step 成功不能只靠 exit code 或 stdout，必須有 artifact contract。

完整流程：

```text
step inputs
  -> agent session
  -> raw output
  -> materialized artifact
  -> handoff summary
  -> schema / contract validation
  -> runtime registry update
```

需要完成：

- [ ] artifact registry
- [ ] artifact lineage
- [ ] handoff schema validator
- [ ] required output check
- [ ] failure marker check
- [ ] JSON extraction / validation
- [ ] Markdown required section validation
- [ ] capability-specific validators
- [ ] Watcher / Security / QA gates
- [ ] route_back_to handling

目前已有雛形：

- `runtime-state.json`
- `artifact-index.md`
- handoff summary fallback
- failure marker detection

## 10. Phase 8: Result Report and Run Archive

目標：每次 run 最後有完整結案報告，而不只是 stdout 與零散 artifact。

目標產物：

```text
result.md
runtime-state.json
agent-sessions.json
artifact-index.md
binding-report.json
compiled-workflow.json
task-constitution.json
workflow.log
```

`result.md` 應包含：

- Summary
- Project Constitution
- Task Constitution
- Compiled Workflow
- Binding Report
- Agent Sessions
- Artifacts
- Failures / skipped / blocked reasons
- Governance gate status
- Promote candidates

需要完成：

- [x] initial `result.md`
- [ ] result report builder
- [ ] final archive hook
- [ ] Logger integration
- [ ] failure summary
- [ ] promote candidates
- [ ] `cap workflow inspect <run-id>` 讀取 result

## 11. Phase 9: Governance Gates

目標：Watcher / Security / QA / Logger 不只存在於 prompt，而是可被 runtime enforce。

完整流程：

```text
step completed
  -> if checkpoint
      -> run watcher / security / qa / logger session
      -> validate gate result
      -> pass: continue
      -> fail: reroute / halt
```

需要完成：

- [ ] watcher checkpoint runner
- [ ] security checkpoint runner
- [ ] qa checkpoint runner
- [ ] logger milestone runner
- [ ] gate result schema
- [ ] fail route handling
- [ ] rerun failed gate
- [ ] halt-on-risk enforcement

Workflow governance target：

```yaml
governance:
  watcher_mode: milestone_gate
  security_mode: risk_based
  qa_mode: post_implementation
  logger_mode: milestone_log
```

## 12. Phase 10: Repo-specific Source Resolver

目標：每個 repo 可以有自己的 Project Constitution、skills 與 workflows，同時仍可使用 CAP builtin baseline。

支援路徑：

```text
.cap.skills.yaml
.cap.constitution.yaml
agent-skills/
workflows/
schemas/workflows/
skills/
```

### Phase 10 前置決策：roles / skills / policies 語意分層

目前 `agent-skills/` 仍是 builtin 開發角色的 SSOT，語意上比較接近「AI 角色」而不是廣義 skill。後續 repo-specific source resolver 需要支援三種使用者擴充：

1. 使用者自行引入角色（例如 product owner、domain reviewer）。
2. 使用者覆寫或調整既有開發角色。
3. 使用者新增非角色型 skill，也就是可套用到多個角色的工作規範。

因此長期模型應拆成：

```text
Role     = AI 的身份、責任與輸出邊界
Skill    = 可被角色套用的工作能力或行為規範
Policy   = 必須遵守的治理規則
Workflow = 把 roles + skills + policies 編排成任務流程
```

實作順序不要求等到 Phase 10 全部完成才開始設計，但實體資料夾重構必須等 source resolver 具備 `project > shared > builtin > legacy` priority 與 conflict detection 後再做。Phase 10 之前只做文件化與 registry contract 準備，避免先搬動 `agent-skills/` 造成 CrewAI / Claude / Codex 入口與 legacy binding 斷裂。

過渡期保留 `agent-skills/` 作為 builtin role legacy path；新的 repo-local 結構由 Phase 10 resolver 正式承接，例如：

```text
.cap/
  roles/
  skills/
  policies/
  workflows/
```

來源層級：

```text
project
shared
builtin
legacy
```

需要完成：

- [ ] project source resolver
- [ ] builtin source resolver
- [ ] shared registry resolver
- [ ] source priority
- [ ] source root allowlist
- [ ] source validation
- [ ] conflict detection
- [ ] binding report shows source layer

## 13. Phase 11: Promote / Publish

目標：runtime artifact 可以經審查後升級成 repo source of truth，但 `.cap` 不會自動變成正式來源。

完整流程：

```text
runtime artifact
  -> review
  -> promote
  -> repo source of truth
```

需要完成：

- [ ] `cap promote list`
- [ ] `cap promote inspect <artifact>`
- [ ] `cap promote <artifact> <repo-path>`
- [ ] `cap promote project-constitution <snapshot-id>`
- [ ] `cap promote workflow <compiled-workflow-id>`
- [ ] source artifact metadata
- [ ] target path policy
- [ ] overwrite protection
- [ ] diff preview
- [ ] validation after promote
- [ ] trace record

## 14. Phase 12: Background Runtime

目標：CAP 支援背景執行、查詢、取消與恢復。

CLI：

```bash
cap workflow run -d <workflow> "<prompt>"
cap workflow ps
cap workflow ps --all
cap workflow inspect <run-id>
cap workflow cancel <run-id>
```

需要完成：

- [ ] detached process model
- [ ] pid file
- [ ] run state update
- [ ] log streaming
- [ ] cancellation
- [ ] orphan detection
- [ ] recovery
- [ ] inspect result / sessions / artifacts

## 15. Phase 13: CLI Final Shape

建議最終 CLI 分層：

```bash
cap project init
cap project status
cap project constitution "<prompt>"
cap project promote-constitution <snapshot-id>

cap workflow list
cap workflow show <id>
cap workflow plan <id>
cap workflow bind <id>
cap workflow run <id> "<prompt>"
cap workflow inspect <run-id>

cap task plan "<prompt>"
cap task compile "<prompt>"
cap task run "<prompt>"
cap task inspect <run-id>

cap session list <run-id>
cap session inspect <session-id>

cap promote list
cap promote inspect <artifact>
cap promote <artifact> <repo-path>
```

可保留目前 `cap workflow compile / run-task`，但長期應補 `cap task ...` 讓語意更乾淨。

## 16. Phase 14: Test Matrix

完整平台需要 fake provider 測完整流程，避免 CI 必須真的呼叫 Codex / Claude。

需要測：

- [ ] schema parse
- [ ] Project Constitution validation
- [ ] Task Constitution compiler
- [ ] Supervisor structured output parser
- [ ] RuntimeBinder
- [ ] source resolver
- [ ] AgentSessionRunner with fake provider
- [ ] shell provider
- [ ] artifact materialization
- [ ] result report
- [ ] promote
- [ ] background run
- [ ] failure / blocked / skipped cases

Fake provider：

```text
FakeProviderAdapter
  -> does not call Codex / Claude
  -> returns fixed stdout / stderr / exit code
  -> supports timeout / failure / invalid output scenarios
```

## 17. Milestone Rollup

### M1: Contracts Complete

- Project Constitution
- Task Constitution
- Capability Graph
- Compiled Workflow
- Binding Report
- Agent Session
- Workflow Result
- Gate Result

### M2: Project Constitution Runner

- `cap project constitution`
- Supervisor produces Project Constitution
- schema validation
- snapshot save
- promote to repo

### M3: Supervisor Orchestration

- structured orchestration
- task constitution
- capability graph
- compiled workflow draft
- validation / retry / halt

### M4: AgentSessionRunner

- provider adapter abstraction
- Codex / Claude / Shell adapters
- prompt snapshot
- session lifecycle
- complete `agent-sessions.json`

### M5: Artifact Validation and Result Archive

- artifact registry
- handoff validation
- complete `result.md`
- failure summary
- inspect run

### M6: Governance Gates

- watcher
- security
- qa
- logger
- reroute / halt / retry

### M7: Repo-specific Sources and Promote

- project workflows
- project skills
- source resolver
- promote / publish

### M8: Background Runtime

- detached run
- ps / inspect / cancel
- recovery
- run lifecycle

## 18. Final Completion Checklist

- [ ] 安裝後可在任一 repo 使用 CAP
- [ ] CAP 可建立並辨識 project storage
- [ ] CAP 可產生 Project Constitution
- [ ] Project Constitution 可被 schema 驗證
- [ ] Project Constitution 可 promote 回 repo
- [ ] Supervisor 可根據 prompt 產生 structured orchestration
- [ ] runtime 可產生 Task Constitution
- [ ] runtime 可產生 Capability Graph
- [ ] runtime 可編譯 executable workflow
- [ ] runtime 可 binding 到 agent skills
- [ ] runtime 可建立 CAP Agent Sessions
- [ ] Codex / Claude 只是 provider adapter
- [ ] 每個 session 有 lifecycle 與 artifact lineage
- [ ] 每次 run 有 `result.md`
- [ ] 每次 run 有 `runtime-state.json`
- [ ] 每次 run 有 `agent-sessions.json`
- [ ] Watcher / Security / QA / Logger 可作為治理 gate
- [ ] `.cap` 只保存 runtime state
- [ ] repo 保存正式 source of truth
- [ ] runtime artifact 可 promote
- [ ] 支援 repo-specific skills / workflows
- [ ] 支援 background run / inspect / cancel
