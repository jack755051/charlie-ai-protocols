<h1 align="center">CAP</h1>

<p align="center">
  <strong>Charlie&apos;s AI Protocols</strong>
</p>

<p align="center">
  <code>shared constitution</code> · <code>agent skills</code> · <code>workflow schema</code> · <code>runtime storage</code>
</p>

<p align="center">
  本地 AI agent 協作規範與 CLI 工具，用來整理角色分工、workflow 與執行紀錄。
</p>

<p align="center">
  <a href="docs/cap/PLATFORM-GOAL.md">Platform Goal</a>
  ·
  <a href="docs/cap/ARCHITECTURE.md">Architecture</a>
  ·
  <a href="docs/cap/IMPLEMENTATION-ROADMAP.md">Roadmap</a>
  ·
  <a href="workflows/README.md">Workflows</a>
</p>

<p align="center">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white">
  <img alt="CrewAI" src="https://img.shields.io/badge/CrewAI-1.14+-000000">
  <img alt="Shell" src="https://img.shields.io/badge/Shell-Bash%2FZsh-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Agents" src="https://img.shields.io/badge/Agents-17-blueviolet">
  <img alt="Status" src="https://img.shields.io/badge/status-active-22c55e">
</p>

```bash
cap workflow run --strategy auto version-control "版本更新"
```

| Protocol Layer | Runtime Surface | Contract |
|---|---|---|
| Constitution | `.cap.constitution.yaml` | repo governance |
| Agent Skills | `agent-skills/` | role boundaries |
| Workflows | `schemas/workflows/` | repeatable execution |
| Storage | `~/.cap/projects/<project_id>/` | traces, reports, bindings |

---

## Purpose

CAP 想處理的問題是：當多位 AI Agent 共同參與軟體開發流程時，如何把角色分工、交接內容、執行紀錄與常用流程整理成可追蹤的形式。

它提供四個核心能力：

- Agent Skills：定義 17 位 Agent 的角色邊界與輸出責任
- Core Protocol：以共享憲法統一所有 Agent 的行為準則
- Workflow Schema：把固定流程抽成可重複使用的結構化定義
- CAP CLI：提供安裝、調用、workflow 檢視、trace 與版本管理

CAP 的產品目標請看 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)，實現路線請看 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)。

## Scope

- In scope：Agent Skills、共享憲法、workflow schema、CrewAI 執行引擎、`cap` CLI、runtime storage 與 README / manifest 治理
- Out of scope：產品業務模組、對外 API 服務、Web UI 與獨立部署中的應用程式邏輯

## Architecture

CAP 採用 shared constitution + specialized agents + workflow schema 的多層架構。
`agent-skills/` 定義角色邊界，`schemas/workflows/` 定義流程契約，`engine/` 負責載入與執行，`scripts/` 提供 `cap` CLI 包裝與本機操作入口，執行期輸出則落到 `~/.cap/projects/<project_id>/`。

同時，CAP 明確區分三種資產：

- 平台內建資產：CAP repo 內建的 base agent-skills、base workflows、capability contracts、binder / compiler / promote 機制
- 專案正式來源：各 repo 自己的 `Project Constitution`、skill registry、workflow definitions
- Runtime Workspace：由 `cap workflow constitution / compile / run-task` 寫入 `~/.cap/projects/<project_id>/` 的快照、binding、compiled workflow、trace 與 reports

目標執行生命週期：

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

目前已實作到 workflow compile / bind / foreground step execution；Supervisor structured orchestration 與正式 Agent Session Ledger 是下一階段重構重點。

## At A Glance

| 元件 | 位置 | 用途 |
|---|---|---|
| Agent Skills | `agent-skills/` | 角色 prompt SSOT |
| Policies | `policies/` | Git、storage、README 治理等跨工具規範 |
| Workflows | `schemas/workflows/` | 固定流程定義與 workflow schema |
| Capabilities | `schemas/capabilities.yaml` | capability 契約 SSOT |
| Engine | `engine/` | CrewAI 與 workflow loader |
| CLI Scripts | `scripts/` | `cap` 子命令與 wrapper |
| Runtime Storage | `~/.cap/projects/<project_id>/` | constitutions、compiled-workflows、bindings、reports、traces |
| Agent Sessions | `~/.cap/projects/<project_id>/sessions/` | 目標中的一次性 sub-agent session ledger |

平台目標請看 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)。
完整實現路線請看 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)。
架構細節請看 [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)（含 Executor Watchdog、Task-Scoped Compiler、Handoff Ticket 參考）。
Skill runtime 架構與 marketplace draft 請看 [docs/cap/SKILL-RUNTIME-ARCHITECTURE.md](docs/cap/SKILL-RUNTIME-ARCHITECTURE.md)。
可選的本地 skill registry 範例請看 [.cap.skills.example.yaml](.cap.skills.example.yaml)。
平台自身的 repo 級憲法範例請看 [.cap.constitution.yaml](.cap.constitution.yaml)。

目前狀態：完成度與待辦項以 [TODOLIST.md](TODOLIST.md) 為單一索引；該檔再指向 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md) 各 phase 的細節，避免三處（README / TODOLIST / ROADMAP）同時維護同樣的進度清單。

## Project Constitution Model

CAP 作為平台時，應維持以下鐵則：

- `CAP` 是平台，不是每個專案正式 skill / workflow 的唯一內容倉庫
- 每個 repo 都應視為獨立 project，先定義自己的 `Project Constitution`
- `Project Constitution` 與其推導出的正式 skill / workflow 應留在 repo 內版控
- `.cap` 只保存 runtime snapshot 與執行過程產物，不作為正式原文唯一來源

建議的四層模型：

1. Platform Constitution：CAP 自己的全域原則、內建能力與平台邊界
2. Project Constitution：某個 repo 自己的治理規則、限制與允許能力範圍
3. Project Source Assets：某個 repo 的正式 skills / workflows / bindings
4. Runtime Workspace：單次任務編譯出的 constitution snapshot、compiled workflow、bindings、traces、reports

多 repo (`A/B/C/D/E`) 模式下，正確流程是：

1. 在每個 repo 內建立自己的 `Project Constitution`
2. 依該憲法生成或維護該 repo 的 skills / workflows
3. 執行任務時，再由 CAP compile 到 `~/.cap/projects/<project_id>/`

換句話說：

- repo 放 source of truth
- `.cap` 放 runtime state

CAP 需要區分兩種 constitution：

- Project Constitution：repo 的長期治理規則，正式版本應保留在 repo，例如 `.cap.constitution.yaml`
- Task Constitution：單次 prompt 的執行憲法，通常保存為 `~/.cap/projects/<project_id>/constitutions/` 的 runtime snapshot

目前 `cap workflow constitution` 較接近 task constitution 產生器；目標是補齊由 `project-constitution.yaml` 與 `01-supervisor-agent.md` 驅動的 Project Constitution 產生流程。

## Project Structure

```text
charlie-ai-protocols/
├── agent-skills/
│   ├── strategies/
│   └── *-agent.md
├── policies/
├── workflows/
├── docs/
│   └── cap/
│       ├── ARCHITECTURE.md
│       ├── EXECUTION-LAYERING.md
│       ├── PLATFORM-GOAL.md
│       ├── IMPLEMENTATION-ROADMAP.md
│       └── SKILL-RUNTIME-ARCHITECTURE.md
├── schemas/
│   ├── workflows/
│   ├── capabilities.yaml
│   ├── skill-registry.schema.yaml
│   ├── project-constitution.schema.yaml
│   └── task-constitution.schema.yaml
├── engine/
├── scripts/
├── AGENTS.md
├── CLAUDE.md
├── Makefile
├── .cap.constitution.yaml
├── .cap.project.yaml
├── repo.manifest.yaml
└── .cap.agents.json
```

執行期資料會寫到：

```text
~/.cap/projects/<project_id>/
├── constitutions/
├── compiled-workflows/
├── bindings/
├── reports/workflows/
├── traces/
└── sessions/
```

## Runbook

安裝：

```bash
bash install.sh

# 或使用遠端安裝腳本
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
source ~/.zshrc
```

初始化：

```bash
cap setup
cap sync
```

常用指令：

```bash
cap help
cap skill list
cap workflow list
cap workflow ps
cap workflow show version-control
cap version
cap release-check --recent 10
cap workflow bind version-control
cap workflow plan version-control
cap workflow run --strategy auto version-control "版本更新"
cap workflow run --strategy governed version-control "正式發版並同步 CHANGELOG / README"
cap workflow constitution "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow compile "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run-task --dry-run "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run --dry-run workflow-smoke-test "test"
cap workflow run version-control "請針對目前變更建立 commit"
```

測試與驗證：

- `test`: `not_applicable`，目前 repo 沒有獨立 automated test target
- smoke / validation：`cap skill check-aliases`
- workflow dry-run：`cap workflow run --dry-run workflow-smoke-test "test"`

## Usage Modes

### 1. Skill Mode

適合單點任務、人工主導流程：

```text
$qa 請幫我針對這段 API 寫單元測試。
$readme 請幫我把這個 repo 的 README 正規化成可機器解析格式。
```

或用 CLI：

```bash
cap agent frontend "幫我檢查 auth module"
cap agent troubleshoot "根據這段 log 找 root cause"
```

### 2. Workflow Mode

適合固定步驟、依賴明確、需要可重複交付的流程。

```bash
cap workflow list
cap workflow ps
cap workflow wf_a4cfb7ad
cap workflow plan version-control
cap workflow run --strategy auto version-control "版本更新"
cap workflow run --dry-run workflow-smoke-test "test"
cap workflow run version-control "請針對目前變更建立 commit"
```

目前 `cap workflow` 支援：

- `list`：表格式列出 workflow、狀態、執行次數與摘要
- `ps`：列出每次 workflow run instance 的狀態摘要
- `show`：inspect 風格檢視單一 workflow
- `inspect`：檢視單一 `run_id` 的執行狀態
- `plan`：顯示 phase、capability 與 agent 綁定
- `constitution`：從一句話需求產出 task constitution
- `compile`：從一句話需求編譯最小 workflow
- `run-task`：從一句話需求直接 compile 並執行
- `run`：有 prompt 時進入前景執行；沒有 prompt 時會先詢問或只顯示 plan
- `run --strategy fast|governed|strict|auto`：在同一 workflow 中切換執行策略或自動判斷
- `run --dry-run`：只顯示執行計畫，不真的執行 step

Workflow 清單請看 [workflows/README.md](workflows/README.md)。

## Agent System

目前共 17 位 Agent，分成四類：

- 治理：`01 Supervisor`
- 交付：`02 Tech Lead`、`02a BA`、`02b DBA/API`、`03 UI`、`12 Figma`、`09 Analytics`、`04 Frontend`、`05 Backend`
- 門禁與維運：`90 Watcher`、`08 Security`、`07 QA`、`10 Troubleshoot`、`11 SRE`、`06 DevOps`
- 收尾與輔助：`99 Logger`、`101 README`

完整說明請看：

- [AGENTS.md](AGENTS.md)
- [agent-skills/README.md](agent-skills/README.md)

## Workflow System

Workflow 與 Agent Skills 是並存的兩種使用方式：

- Agent Skill：描述單一角色能做什麼
- Workflow：描述多步驟流程怎麼串接

目前保留中的 workflow 為：

- `workflow-smoke-test.yaml`：workflow CLI 與 capability binding 的煙霧測試
- `readme-to-devops.yaml`：README 治理到 DevOps 基線
- `version-control.yaml`：版本控制流程（三段 pipeline + strategy + lint 守門）
- `project-constitution.yaml`：從一句話需求產出 Project Constitution（4-step bootstrap → draft → validate → persist）
- `project-constitution-reconcile.yaml`：在既有 Project Constitution 基礎上吸收 addendum，一次性收斂出修正版並覆寫 SSOT；persist step 支援 `CAP_CONSTITUTION_DRY_RUN=1` 預覽 diff、覆寫前自動備份至 `.cap.constitution.yaml.backup-<TIMESTAMP>`

版本控制 workflow 統一採三段 pipeline：

- `vc_scan` (shell, `scripts/workflows/vc-scan.sh`)：scan + 守門 + 輸出結構化 evidence pack
- `vc_compose` (AI, devops agent)：純語意工作；根據 evidence 產出 commit envelope JSON
- `vc_apply` (shell, `scripts/workflows/vc-apply.sh`)：lint envelope（subject 必含 path token、禁止抽象主動詞、annotation/changelog 條目過 lint），通過後執行 git ops

策略：

- `fast`：`vc_compose` 強制 `release.perform_release=false`；不做 tag / CHANGELOG / README 同步
- `governed`：依 `release_intent` 自然走 release 或 commit-only；發版時 amend CHANGELOG / README 並建立 annotated tag
- `strict`：高治理場景；compose 對重大、跨模組、schema 或 CLI 變更要求 body 敘述影響範圍與遷移步驟

`cap workflow run --strategy auto version-control "版本更新"` 會由 runtime selector 自動選擇 strategy；目前 selector 是規則式，不會額外多叫一個 router agent。

相關入口：

- [workflows/README.md](workflows/README.md)
- [workflows/workflow-schema.md](workflows/workflow-schema.md)
- [schemas/capabilities.yaml](schemas/capabilities.yaml)
- [schemas/project-constitution.schema.yaml](schemas/project-constitution.schema.yaml)
- [schemas/task-constitution.schema.yaml](schemas/task-constitution.schema.yaml)
- [schemas/agent-session.schema.yaml](schemas/agent-session.schema.yaml)

## Workflow Storage Model

workflow 目前分成兩種層級，避免把 runtime 產物塞回主程式 repo：

- `schemas/workflows/*.yaml`
  - 內建 workflow 模板與固定流程範本
  - 屬於 repo 內的可版本化定義
- `.cap.constitution.yaml`
  - repo 級 `Project Constitution`
  - 定義此專案的治理原則、正式來源位置與 runtime / source 分層
- `.cap.skills.yaml`
  - repo 級 skill registry / binding source
  - 可指向該專案自己的 skill 與 capability 綁定
- `~/.cap/projects/<project_id>/constitutions/`
  - 一句話需求推導出的 task constitution snapshot
- `~/.cap/projects/<project_id>/compiled-workflows/`
  - `run-task` 或 `compile` 產生的 task-scoped compiled workflow bundle
- `~/.cap/projects/<project_id>/bindings/`
  - `bind / run / run-task` 實際用到的 binding report snapshot
- `~/.cap/projects/<project_id>/reports/workflows/`
  - 每次執行的 artifact、handoff、runtime state、agent sessions、result report、watchdog log

這代表：

- 主 repo 保留模板、schema、engine、CLI
- 單次任務的 constitution / compiled workflow / binding / run output 都進 `.cap`
- 專案正式 constitution / skills / workflows 應與該 repo 一起版控
- 只有真正要長期維護的 custom workflow，才應升級成 repo 內檔案

## Interfaces

- CLI：`true`，主入口為 `scripts/cap-entry.sh` 與 `Makefile`
- API：`false`
- Worker：`false`
- Cron：`false`
- Web UI：`false`

## Dependencies

- Python `>= 3.10`
- CrewAI `>= 1.14`
- `python-dotenv`
- `PyYAML`
- Bash / Zsh
- GNU Make

選用消費端：

- Claude Code：透過 `@import` 掛載協議
- OpenAI Codex：透過 `$prefix` 與 `cap agent` 使用 Agent Skills

## Notes

- 最新已驗證 tag：`v0.22.0-rc2`（pending — 待使用者確認 release / push 策略）
- v0.22.0-rc2 重點：close P1「Project Storage and Identity」整段 7 個 milestone，把 v0.22.0-rc1 P0 contract 落地後的 storage / identity 閉環跑完 —— `1acda13` P1 #1 cap-paths strict-mode resolver（exit 52 / `ProjectIdResolutionError`）+ P1 #2 identity ledger collision（exit 53 / `ProjectIdCollisionError`）/ `02a60c0` P1 #3 ledger schema v2 + `policies/cap-storage-metadata.md` SSOT（11 fixtures + 47 resolver assertions）/ `0f27324` P1 #4 `engine/storage_health.py` read-only diagnostic core（12 種 `HealthIssueKind`，schema-class→41、collision→53、generic error→1、warning-only→0；read-only 嚴禁寫 ledger）+ `scripts/cap-storage-health.sh` 薄 wrapper（10 cases + 1 conditional / 26 assertions）/ `982ca90` P1 #6 `cap project init`（`scripts/cap-project.sh` 統一入口，委派 cap-paths.sh ensure；10 cases / 33 assertions）/ `f0eebc0` P1 #5 `cap project status`（`engine/project_status.py` 重用 health-check core；8 cases / 21 assertions）/ `a9174bc` P1 #7 `cap project doctor`（`engine/project_doctor.py` read-only by design，`REMEDIATIONS` 覆蓋全部 12 種 `HealthIssueKind`；10 cases / 31 assertions）。整段升 `smoke-per-stage.sh` 至 27 step / **27 passed / 0 failed / 0 skipped**。本 tag 仍為 release candidate，標 P1 整段乾淨節點，後續 P2（Project Constitution Runner）可開工。
- v0.22.0-rc1 重點：close P0「Runtime Contracts」段 6 schema，補齊 supervise → run → gate triad 的 forward / normalized contracts —— `08a7af8` capability-graph (P0 #1, direct, 8 fixtures) / `1cda0ee` compiled-workflow (P0 #2, direct, 9 fixtures) / `d942923` binding-report (P0 #3, direct, 10 fixtures) / `82ad424` supervisor-orchestration (P0 #4, **forward**, 10 fixtures, producer 留 P3) / `cdd5701` workflow-result (P0 #5, **normalized**, 10 fixtures, producer 留 P7) / `c8d143d` gate-result (P0 #6, **forward**, 10 fixtures, producer 留 P8)；47 fixture cases 全進 `smoke-per-stage.sh`：21 step / **21 passed / 0 failed / 0 skipped**。`a59675f` `TODOLIST.md` Phase 1 同步翻 [x]。本 tag 為 release candidate，標 P0 整段乾淨節點，後續 P1（Project Storage and Identity）可開工。
- v0.21.6 重點：完成 P0a 並通過 v0.21.5 → v0.22.0 fresh provider parity baseline gate —— (1) `5b31856` 6 個 schema-class executor（`validate-constitution` / `emit-handoff-ticket` / `ingest-design-source` / `bootstrap-constitution-defaults` / `persist-constitution` / `load-constitution-reconcile-inputs`）`fail_with` exit 40 → 41，跟 vc-class exit 40 正式分流；4 個新 exit-41 unit smoke + 2 個既有測試斷言更新，smoke-per-stage 11 → 15 step / 15 passed；(2) `44011ad` `policies/workflow-executor-exit-codes.md` 補 row 41 + Script Classification 段，加 `PROVIDER-PARITY-FRESH-E2E-V0.21.5.md` runbook；(3) Fresh Claude + Codex `project-spec-pipeline` full run 各 16/16 完成、parity check 各 43/0、duration 差 17s，v0.21.5 三件 fix 在 fresh runtime 無 regression，v0.22.0 P0 runtime contracts 基線乾淨可開工。
- v0.21.5 重點：(1) `1425fa9` task project identity 對齊 cap-paths runtime resolver，收斂 v0.21.3 標的 R3 deferred；(2) `55038dd` `persist-task-constitution.sh` 自動 strip Claude / Codex 在 task constitution fence 內又包一層 ```` ```json ```` 的 nested fence，避免 JSON parse halt；(3) `2492913` parity-check §4.2 區分 Type B nonempty 欄位與 `non_goals` present-only 欄位，允許 `non_goals=[]` 表示「沒有排除項」，但 `success_criteria=[]` / `execution_plan=[]` 仍 FAIL；claude / codex 既有 parity run 重跑皆為 43/0，新增 provider parity checker smoke 並納入 `smoke-per-stage.sh`。
- v0.21.4 重點：parity-check §4.5 合併 undeclared/none design-source 為 lenient PASS（修對 UI agent 交付物的 false positive，codex parity 41/5 → 42/1）；03-ui-agent §4 加硬性「必須實際寫檔」規範，禁止 claude UI step 用 stdout / handoff 占位語意取代真實寫檔。
- v0.21.3 重點：claude `project-spec-pipeline` 從 3/16 step_failed 推到 16/16 completed，parity check 22/16 → 42 PASS / 1 FAIL — workflow step 新增 `optional_inputs` 欄位讓 graceful no-op 可被 shell 真正執行、`cap-workflow-exec.sh` 補 6 個 block 路徑的 log/RUN_SUMMARY 可觀測性、`persist-task-constitution.sh` 收斂 risk_profile/non_goals schema drift 並把 schema_validation_failed 從 git_operation_failed exit code 拆開。
- v0.21.2 重點：provider parity checker 對齊 archive pattern 與 design source type-aware 判定。
- 近期主軸：design source runtime、provider parity e2e、task constitution strict schema 與 per-stage workflow 穩定化。
- 完整版本紀錄請看 [docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md)。
- 後續尚未實現項目的工程清單見 [docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md](docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md)。

## Links

- 平台目標：[docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)
- 完整實現路線：[docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)
- 架構文件：[docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)
- Agent 清單：[AGENTS.md](AGENTS.md)
- Workflow 清單：[workflows/README.md](workflows/README.md)
- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>

## License

UNLICENSED — Portfolio 專用，保留一切權利。
