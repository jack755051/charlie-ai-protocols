# CAP Platform TODO List

更新日期：2026-05-02

## 目標

CAP 的目標是一個本機 AI workflow runtime 平台，而不是單純的 agent prompt / workflow template 倉庫。

安裝 CAP 並登入 Codex / Claude Code CLI 後，使用者應能在任一資料夾或 repo 中使用基礎 agent skills 與 workflows。CAP 會為該 project 建立 `~/.cap/projects/<project_id>/`，保存 constitution、compiled workflows、bindings、agent sessions、handoffs、reports、traces 與執行結果。

完整目標文檔見 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)。
完整實現路線與開發備忘錄見 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)。
尚未實現項目的可執行清單見 [docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md](docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md)。

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

- [x] 基礎 agent skills 已建立於 `agent-skills/`
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
- [x] `schemas/project-constitution.schema.yaml` 已新增 draft v1
- [x] `agent-sessions.json` executor-level ledger 已落地
- [x] `result.md` human-readable run archive 已落地
- [x] CAP storage policy 已文件化

### Phase 0：Baseline Cleanup（已完成）

> ROADMAP 沒有正式列出的前置整理階段，但實作上必須先有；以下為 v0.13.5 之後的清理工作。

- [x] version-control workflow 拆為三段 pipeline：`vc_scan` (shell) → `vc_compose` (AI) → `vc_apply` (shell)，shell 不猜語意、AI 不重跑 git，apply 階段做出口 lint
- [x] 平台級 doc 收斂進 `docs/cap/`（ARCHITECTURE / PLATFORM-GOAL / IMPLEMENTATION-ROADMAP / SKILL-RUNTIME-ARCHITECTURE / execution-layering）
- [x] Shell / Python / AI 五層分層明文化（`docs/cap/EXECUTION-LAYERING.md`）
- [x] `cap-workflow-exec.sh` 與 `cap-registry.sh` 內 inline `python3 -c` heredoc 抽到 `engine/step_runtime.py` subcommand（`plan-meta` / `parse-input-check` / `registry-list` / `registry-get`）
- [x] `cap-workflow.sh run-task` 分支 `EXECUTION_MODE` / `SELECTED_MODE` unbound vars 修復
- [x] version-control private / quick / company 三變體 yaml 收斂為單一 `version-control.yaml` v7 + `--strategy fast/governed/strict/auto` flag
- [x] `init-ai.sh` 補 `set -euo pipefail`，與其他 `cap-*.sh` 對齊
- [x] dead agent archive (`agent-skills/archive/`) 與 0-byte `.codex` 清除
- [x] `workflow-schema.md` 補 v3-v7 演進說明與 `compatible_workflow_versions` 對 binding 影響

### 尚未完成

- [ ] Project Constitution schema 尚未接上正式 validator
- [ ] `project-constitution.yaml` 尚未成為完整 Project Constitution runner
- [ ] `cap workflow constitution` 目前較接近 task constitution 產生器，語意需拆清楚
- [ ] Supervisor 尚未真正負責 structured orchestration
- [ ] Supervisor 尚未輸出可驗證的 task constitution / capability graph / compiled workflow draft
- [ ] sub-agent 尚未升級為完整 AgentSessionRunner
- [ ] `agent-sessions.json` 尚未紀錄 provider-native session id / prompt snapshot
- [ ] agent session lifecycle 尚未完整紀錄 `created / running / completed / failed / recycled`
- [ ] detached / background workflow run 尚未實作
- [ ] repo-specific workflow / skill source resolver 尚未完整
- [ ] promote / publish 流程尚未閉環

## 完整實現流程摘要

詳細設計、完成標準與最終 checklist 以 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md) 為準；本節保留可勾選的開發追蹤清單，是實際動工時的工作介面。

### Phase 1: Contracts Complete

- [x] 定義 `schemas/project-constitution.schema.yaml`
- [x] 定義 `schemas/task-constitution.schema.yaml`
- [x] 定義 `schemas/agent-session.schema.yaml`
- [x] 定義 `schemas/capabilities.yaml`
- [x] 定義 `schemas/capability-graph.schema.yaml`（v0.22.0 P0 #1，8 fixture cases）
- [x] 定義 `schemas/compiled-workflow.schema.yaml`（v0.22.0 P0 #2，9 fixture cases）
- [x] 定義 `schemas/binding-report.schema.yaml`（v0.22.0 P0 #3，10 fixture cases）
- [x] 定義 `schemas/supervisor-orchestration.schema.yaml`（v0.22.0 P0 #4，forward contract，10 fixture cases；producer 留 P3 SupervisorOrchestrator）
- [x] 定義 `schemas/workflow-result.schema.yaml`（v0.22.0 P0 #5，normalized contract，10 fixture cases；builder 留 P7 result report builder）
- [x] 定義 `schemas/gate-result.schema.yaml`（v0.22.0 P0 #6，forward contract，10 fixture cases；producer 留 P8 governance gate runners）

> Phase 1 整段於 v0.22.0 (in-progress) 全綠；6 schema 共 47 fixture cases 透過 `tests/scripts/test-*-schema.sh` 驗證並 wire 進 `scripts/workflows/smoke-per-stage.sh`（21/21 pass）。Forward / normalized contract 的 producer 落地分散在 Phase 4 / 8 / 9，但 contract 已先立。

### Phase 2: Project Storage and Identity

- [x] `cap paths` 顯示 project storage
- [x] `.cap.project.yaml` 作為 project identity source
- [x] git root basename fallback
- [x] 支援非 git folder 的 project id 策略（v0.22.0 P1 #1，strict mode + `CAP_ALLOW_BASENAME_FALLBACK` 後門）
- [x] 處理 project id collision（v0.22.0 P1 #2，inline `.identity.json` ledger + shell exit 53 / Python `ProjectIdCollisionError`）
- [x] 記錄 storage version / migration metadata（v0.22.0 P1 #3，`schemas/identity-ledger.schema.yaml` v2 normalized contract + `policies/cap-storage-metadata.md` 政策 SSOT；cap-paths.sh 與 project_context_loader.py lock-step v1→v2 auto-migrate；ledger 記錄 schema_version / created_at / last_resolved_at / migrated_at / cap_version / previous_versions[]，11 schema fixture cases + resolver 47 assertions / smoke 23/23）
- [x] 實作 storage health check（v0.22.0 P1 #4，`engine/storage_health.py` read-only diagnostic core + `scripts/cap-storage-health.sh` shell wrapper；12 種 `HealthIssueKind` 涵蓋缺目錄 / 缺 ledger / 壞 metadata / forward-incompat / schema drift / origin collision / cap_version 漂移 / 不可寫 storage 等場景；exit code 對齊 `policies/workflow-executor-exit-codes.md`：schema-class→41、collision→53、generic error→1、warning-only→0；read-only 嚴禁寫 ledger；10 cases + 1 conditional / 26 assertions / smoke 24/24）
- [ ] 新增 `cap project status`
- [ ] 新增 `cap project init`
- [ ] 新增 `cap project doctor`

### Phase 3: Project Constitution Runner

- [ ] 明確區分 Project Constitution 與 Task Constitution
- [ ] 調整 `schemas/workflows/project-constitution.yaml` 的輸出契約
- [ ] 讓 Project Constitution workflow 產出 Markdown 與 JSON
- [ ] 實作 Project Constitution validator
- [ ] 實作 agent output JSON extraction
- [ ] 對 Project Constitution JSON 做 schema validation
- [ ] validation failure 時 halt
- [ ] 將通過驗證的 Project Constitution snapshot 保存到 CAP storage
- [ ] 實作 constitution snapshot versioning
- [ ] 提供 promote 或 init 路徑，將正式 Project Constitution 寫回 repo

- [ ] 決定 `cap workflow constitution` 是否保留為 task constitution 入口
- [ ] 新增或規劃 `cap project constitution "<prompt>"`
- [ ] 新增 `cap project constitution --promote`
- [ ] 新增 `cap project constitution --dry-run`
- [ ] 新增 `cap project constitution --from-file`
- [ ] 文件化 `constitution / compile / run-task / run` 的差異
- [ ] 更新 CLI help，避免 Project Constitution 與 Task Constitution 混用

### Phase 4: Supervisor Structured Orchestration

- [ ] 定義 Supervisor orchestration output schema
- [ ] 實作 `SupervisorOrchestrator`
- [ ] 實作 supervisor prompt builder
- [ ] Supervisor 讀取 Project Constitution、user prompt、repo context
- [ ] Supervisor 產出 task constitution
- [ ] Supervisor 產出 capability graph
- [ ] Supervisor 產出 compiled workflow draft
- [ ] Supervisor 標註 Watcher / Security / QA / Logger checkpoint
- [ ] 實作 structured output parser
- [ ] runtime 驗證 Supervisor 輸出，不接受純自然語言派工
- [ ] invalid output 時 retry / halt
- [ ] 保存 orchestration snapshot

### Phase 5: Compiled Workflow and Binding Pipeline

- [ ] 實作 compiled workflow schema validation
- [ ] 實作 binding report schema validation
- [ ] 強化 compiled workflow normalization
- [ ] 實作 project / shared / builtin / legacy source priority
- [ ] enforce allowed capabilities
- [ ] enforce allowed workflow source roots
- [ ] enforce fallback policy
- [ ] 強化 unresolved handling
- [ ] 產出 preflight report
- [ ] 強化 dry-run inspection

### Phase 6: AgentSessionRunner

- [x] 定義 `schemas/agent-session.schema.yaml` 的 runtime 實例欄位
- [x] 在每個實際執行的 workflow step 前建立 `session_id`
- [x] 記錄 `run_id / workflow_id / step_id / capability / agent_alias / prompt_file / provider_cli`
- [x] 記錄 input mode 與 output artifact
- [x] 記錄 handoff path
- [x] 記錄 status 與 failure reason
- [x] 每次 run 產出 `agent-sessions.json`
- [ ] 實作 `AgentSessionRunner`
- [ ] 定義 `ProviderAdapter` interface
- [ ] 實作 `CodexAdapter`
- [ ] 實作 `ClaudeAdapter`
- [ ] 實作 `ShellAdapter`
- [ ] 補 provider-native session id
- [ ] 補 prompt snapshot / prompt hash
- [ ] 捕捉 provider stdout / stderr
- [ ] 整合 timeout / stall
- [ ] 支援 parent / child session relation
- [ ] workflow 結束後將 session 標記為 `completed / failed / cancelled / recycled`
- [ ] 新增 `cap session inspect`

### Phase 7: Artifact, Handoff and Validation

- [x] `runtime-state.json` 雛形
- [x] `artifact-index.md` 雛形
- [x] handoff summary fallback
- [x] failure marker detection
- [ ] 實作 artifact registry
- [ ] 實作 artifact lineage
- [ ] 實作 handoff schema validator
- [ ] 實作 required output check
- [ ] 實作 JSON extraction / validation
- [ ] 實作 Markdown required section validation
- [ ] 實作 capability-specific validators
- [ ] 實作 route_back_to handling

### Phase 8: Result Report and Run Archive

- [x] 每次 run 產出初版 `result.md`
- [ ] 實作 result report builder
- [ ] `result.md` 彙整 constitution、compiled workflow、binding、sessions、artifacts、failures
- [ ] 明確區分 `runtime-state.json` 與人類可讀 result report
- [ ] 補 failure summary
- [ ] 補 promote candidates
- [ ] 補 final archive 規則，讓 Logger (99) 可接手整理結案摘要
- [ ] `cap workflow inspect <run-id>` 讀取 result

### Phase 9: Governance Gates

- [ ] 實作 watcher checkpoint runner
- [ ] 實作 security checkpoint runner
- [ ] 實作 qa checkpoint runner
- [ ] 實作 logger milestone runner
- [ ] 定義 gate result schema
- [ ] 實作 fail route handling
- [ ] 支援 rerun failed gate
- [ ] enforce halt-on-risk

### Phase 10: Repo-specific Source Resolver

- [ ] 支援 repo-local workflow source roots
- [ ] 支援 repo-local skill registry
- [ ] 明確區分 builtin / project / shared skill source
- [ ] 套用 Project Constitution 的 allowed source roots
- [ ] 實作 shared registry resolver
- [ ] 實作 source validation
- [ ] 實作 conflict detection
- [ ] binding report 顯示每個 step 使用的 source layer

### Phase 11: Promote / Publish

- [ ] 定義 runtime artifact promote 回 repo 的規則
- [ ] 定義 project skill / workflow publish 到 shared registry 的規則
- [ ] 實作 `cap promote inspect <artifact>`
- [ ] 實作 `cap promote project-constitution <snapshot-id>`
- [ ] 實作 `cap promote workflow <compiled-workflow-id>`
- [ ] 實作 overwrite protection
- [ ] 實作 diff preview
- [ ] 實作 validation after promote
- [ ] 補 `cap promote` 文件與範例
- [ ] 避免 `.cap` runtime snapshot 被誤當正式 source of truth

### Phase 12: Background Runtime

- [ ] 設計 detached run 的 process model
- [ ] 讓 `cap workflow run -d` 真正執行背景任務
- [ ] `cap workflow ps` 顯示 running / completed / failed
- [ ] `cap workflow inspect <run-id>` 顯示 session、artifact 與 failure 摘要
- [ ] 實作 pid file
- [ ] 實作 log streaming
- [ ] 實作 cancellation
- [ ] 實作 orphan detection
- [ ] 實作 recovery

### Phase 13: CLI Final Shape

- [ ] `cap project init`
- [ ] `cap project status`
- [ ] `cap project constitution "<prompt>"`
- [ ] `cap task plan "<prompt>"`
- [ ] `cap task compile "<prompt>"`
- [ ] `cap task run "<prompt>"`
- [ ] `cap session list <run-id>`
- [ ] `cap session inspect <session-id>`

### Phase 14: Test Matrix

- [ ] schema parse tests
- [ ] Project Constitution validation tests
- [ ] Task Constitution compiler tests
- [ ] Supervisor structured output parser tests
- [ ] RuntimeBinder tests
- [ ] source resolver tests
- [ ] AgentSessionRunner fake provider tests
- [ ] shell provider tests
- [ ] artifact materialization tests
- [ ] result report tests
- [ ] promote tests
- [ ] background run tests
- [ ] failure / blocked / skipped case tests

## 優先順序

1. Contracts Complete
2. Project Storage and Identity
3. Project Constitution Runner
4. Supervisor Structured Orchestration
5. Compiled Workflow and Binding Pipeline
6. AgentSessionRunner
7. Artifact, Handoff and Validation
8. Result Report and Run Archive
9. Governance Gates
10. Repo-specific Source Resolver
11. Promote / Publish
12. Background Runtime
13. CLI Final Shape
14. Test Matrix

## 風險與注意事項

- 不要把 `.cap` runtime snapshot 當成正式原文唯一來源。
- 不要讓 Supervisor 只輸出口頭派工，正式派工必須有 JSON / YAML artifact。
- 不要把 CAP Agent Session 綁死在 Codex 或 Claude 的原生 sub-agent 實作。
- 不要在 Project Constitution 尚未 schema 化前擴張太多 repo-specific workflow 行為。
- 不要優先做 Web UI；目前瓶頸在 runtime 可追蹤性與治理閉環。
