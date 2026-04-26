# CAP Platform TODO List

更新日期：2026-04-26

## 目標

CAP 的目標是一個本機 AI workflow runtime 平台，而不是單純的 agent prompt / workflow template 倉庫。

安裝 CAP 並登入 Codex / Claude Code CLI 後，使用者應能在任一資料夾或 repo 中使用基礎 agent skills 與 workflows。CAP 會為該 project 建立 `~/.cap/projects/<project_id>/`，保存 constitution、compiled workflows、bindings、agent sessions、handoffs、reports、traces 與執行結果。

完整目標文檔見 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)。
完整實現路線與開發備忘錄見 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)。

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
- [x] `schemas/project-constitution.schema.yaml` 已新增 draft v1
- [x] `agent-sessions.json` executor-level ledger 已落地
- [x] `result.md` human-readable run archive 已落地
- [x] CAP storage policy 已文件化

### Phase 0：Baseline Cleanup（已完成）

> ROADMAP 沒有正式列出的前置整理階段，但實作上必須先有；以下為 v0.13.5 之後的清理工作。

- [x] version-control workflow 拆為三段 pipeline：`vc_scan` (shell) → `vc_compose` (AI) → `vc_apply` (shell)，shell 不猜語意、AI 不重跑 git，apply 階段做出口 lint
- [x] 平台級 doc 收斂進 `docs/cap/`（ARCHITECTURE / PLATFORM-GOAL / IMPLEMENTATION-ROADMAP / SKILL-RUNTIME-ARCHITECTURE / execution-layering）
- [x] Shell / Python / AI 五層分層明文化（`docs/cap/execution-layering.md`）
- [x] `cap-workflow-exec.sh` 與 `cap-registry.sh` 內 inline `python3 -c` heredoc 抽到 `engine/step_runtime.py` subcommand（`plan-meta` / `parse-input-check` / `registry-list` / `registry-get`）
- [x] `cap-workflow.sh run-task` 分支 `EXECUTION_MODE` / `SELECTED_MODE` unbound vars 修復
- [x] version-control private / quick / company 三變體 yaml 收斂為單一 `version-control.yaml` v7 + `--strategy fast/governed/strict/auto` flag
- [x] `init-ai.sh` 補 `set -euo pipefail`，與其他 `cap-*.sh` 對齊
- [x] dead agent archive (`docs/agent-skills/archive/`) 與 0-byte `.codex` 清除
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

## Phase 進度索引

> 詳細設計、完成標準、checklist 內每一條目以 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md) 為**單一事實來源**。本節只保留人類可讀的進度摘要，避免兩處重複維護同樣的 `[ ]/[x]` 清單。要更新某個 phase 的具體狀態，請改 ROADMAP 對應段落。

| Phase | 主題 | 摘要狀態 | ROADMAP 對應 |
|---|---|---|---|
| 0 | Baseline Cleanup | ✅ 已完成（見上節） | — |
| 1 | Contracts Complete | 9 份契約有 4 已建（capabilities / project-constitution / task-constitution / agent-session）；缺 capability-graph / compiled-workflow / binding-report / supervisor-orchestration / workflow-result / gate-result | §3 |
| 2 | Project Storage and Identity | `cap paths` / `.cap.project.yaml` / git root fallback ✅；`cap project init / status / doctor`、id collision、storage health 待補 | §4 |
| 3 | Project Constitution Runner | 全未開工（task constitution 入口已混用，需語意拆分） | §5 |
| 4 | Supervisor Structured Orchestration | 全未開工（runtime 仍接受純自然語言派工） | §6 |
| 5 | Compiled Workflow and Binding Pipeline | 等 Phase 1 schema 補齊後再做 validation / source priority / preflight report | §7 |
| 6 | AgentSessionRunner | executor-level `agent-sessions.json` ledger ✅；ProviderAdapter / AgentSessionRunner 抽象、prompt snapshot、recycle 待補 | §8 |
| 7 | Artifact / Handoff / Validation | runtime-state / artifact-index / handoff fallback / failure marker ✅；artifact registry / lineage / schema validator 待補 | §9 |
| 8 | Result Report and Run Archive | `result.md` 雛形 ✅；report builder、failure summary、promote candidates、`cap workflow inspect` 待補 | §10 |
| 9 | Governance Gates | 全未開工（watcher / security / qa / logger gate runner、gate result schema、fail route） | §11 |
| 10 | Repo-specific Source Resolver | 全未開工 | §12 |
| 11 | Promote / Publish | 全未開工 | §13 |
| 12 | Background Runtime | 全未開工（`cap workflow run -d`、ps / inspect / cancel） | §14 |
| 13 | CLI Final Shape | 等 Phase 2 / 3 / 6 完成後再正式收束 cap project / task / session 命令族 | §15 |
| 14 | Test Matrix | 全未開工（fake provider 驅動的回歸測試） | §16 |

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
