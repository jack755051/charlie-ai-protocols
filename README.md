# Charlie's AI Protocols (CAP)

> 工業級 AI 多代理協作框架與 CLI 工具。
> 以共享憲法、Agent Skills、Workflow Schema 與 CAP runtime storage，讓多角色 AI 協作可以被標準化、追蹤與重複使用。

![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)
![CrewAI](https://img.shields.io/badge/CrewAI-1.14+-000000)
![Shell](https://img.shields.io/badge/Shell-Bash%2FZsh-4EAA25?logo=gnubash&logoColor=white)
![Agents](https://img.shields.io/badge/Agents-17-blueviolet)
![Status](https://img.shields.io/badge/status-active-22c55e)

## Purpose

CAP 解決的核心問題是：當多位 AI Agent 共同參與軟體開發流程時，如何維持清楚分工、穩定交接、可追蹤執行紀錄與不可繞過的品質門禁。

它提供四個核心能力：

- Agent Skills：定義 17 位 Agent 的角色邊界與輸出責任
- Core Protocol：以共享憲法統一所有 Agent 的行為準則
- Workflow Schema：把固定流程抽成可重複使用的結構化定義
- CAP CLI：提供安裝、調用、workflow 檢視、trace 與版本管理

CAP 的完整產品目標請看 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)，完整實現路線請看 [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)。

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

- 最新已驗證 tag：`v0.21.2`
- v0.17.0：新增 `project-constitution-reconcile` workflow，用來吸收 addendum 後一次性重構既有 Project Constitution，避免把補充資訊直接混進憲法本體
- v0.17.1：補上 reconcile 安全合約 — persist step 支援 `CAP_CONSTITUTION_DRY_RUN=1` 預覽 diff、覆寫前自動備份至 `.cap.constitution.yaml.backup-<TIMESTAMP>`、watcher 升級為 `milestone_gate` 並對 reconcile / validate / persist 三個 checkpoint 設閘
- v0.18.0：新增 `prompt_outline_normalize` capability 與對應 step，把使用者 prompt 拆成 scalar / array / object / Markdown 四向分流送進憲章 / reconcile 之 draft，避免 schema halt；`cap workflow run` 加上 `--design-source / --design-url / --design-figma-target / --design-script / --no-design` 旗標與 TTY 反問機制（規劃型 workflow 限定），由 `schemas/design-source-templates.yaml` 提供 `claude-design / figma-mcp / figma-import-script` 儀式句模板；同步把 `agent-skills/`、`policies/`、`workflows/` 從 `docs/` 拆出成根目錄一級來源
- v0.18.1：完成「設計來源 package 投放」管線 — `engine/design_prompt.py` 新增 `local-design` 來源、`--design-path` 旗標與 `DEFAULT_DESIGNS_DIR = "~/.cap/designs"` 常數；`schemas/design-source-templates.yaml` 補上 `local-design` 儀式句與 `design_path` 必填欄位；`install.sh` 在 storage setup 同時 mkdir `${CAP_HOME}/projects` 與 `${CAP_HOME}/designs`，老使用者跑 `cap update` 即可自動拿到目錄，與 `design_prompt.py` 只讀不建的契約形成完整鏈路
- v0.19.0：新增 per-stage workflow 系列（`schemas/workflows/project-spec-pipeline.yaml` / `project-implementation-pipeline.yaml` / `project-qa-pipeline.yaml`），把 supervisor 派工迴圈固化為可被 cap CLI 顯示步驟與計時的單元；新增 `schemas/handoff-ticket.schema.yaml`（Type C 派工單契約）+ `task_constitution_planning` / `handoff_ticket_emit` 兩條 capability；`policies/constitution-driven-execution.md` §1.3 新增 Mode C conductor binding 規則（`.cap.constitution.yaml` 存在時 conductor 綁定 01-Supervisor）；`agent-skills/01-supervisor-agent.md` §3.6 / §3.7 把 ticket 發行協議與 conductor 綁定落地到 supervisor 自身行為書
- v0.19.1：補完 v0.19.0 的 binding 與 runtime 缺口 — `.cap.skills.yaml` `builtin-supervisor.provided_capabilities` 補上 `task_constitution_planning` / `handoff_ticket_emit`；自宿主 `.cap.constitution.yaml` `allowed_capabilities` 同步補；新增兩個 deterministic shell（`scripts/workflows/persist-task-constitution.sh`、`scripts/workflows/emit-handoff-ticket.sh`）；新增 `task_constitution_persistence` capability；三條 per-stage workflow 的 `init_task` 拆為 `draft_task_constitution`（ai）+ `persist_task_constitution`（shell）兩段式；新增 `policies/handoff-ticket-protocol.md` 規範非 supervisor sub-agent 的 ticket 讀寫協議，並透過 `agent-skills/00-core-protocol.md` §5.3 跨切引用避免改動 13 份 agent skill
- v0.21.2：v0.21.1 新增的 `scripts/workflows/provider-parity-check.sh` 在實際對 token-monitor 既有 run 驗證後修兩個 checker bug — (1) spec layer §4.6 archive pattern 帶錯誤底線（`_archive`）改為 `archive` 對齊實際檔名 `<phase>-archive.md`；(2) §4.5 design source 區段加入 type-aware 判定（從 cwd 憲法讀 `design_source.type`，依 none / 缺宣告 / 非 none 分流 PASS no-op / 真 FAIL），不再靜默略過缺漏；驗證後對成功 run 報 40 PASS / 3 真實 FAIL、對 halted run 報 28 PASS / 15 FAIL（含 banned alias 3 條）—— 確認 release-gate 工具能落實 v0.21.1 嚴格 schema 的偵測意圖
- v0.21.1：把 v0.20.0–v0.21.0 散落的 design source 規則 / Type B prompt 契約 / provider e2e checklist 收斂成 SSOT — `agent-skills/01-supervisor-agent.md` 新增 §2.5「Task Constitution 嚴格 Schema 契約」明列 8 個固定頂層欄位與**禁用別名清單**（task_summary、user_intent_excerpt、target_capability 等），預告 v0.22.0+ 移除 persist normalizer alias fan-in；新增 `docs/cap/DESIGN-SOURCE-RUNTIME.md`（四層模型 + 三段式解析 + 6 條不變式 + 測試覆蓋）為單一權威藍圖；新增 `docs/cap/PROVIDER-PARITY-E2E.md` checklist + `scripts/workflows/provider-parity-check.sh`（artifact-only 驗收，不呼叫 AI）把 Codex / Claude 真實 e2e 變成可重跑可審計程序；workflow YAML 與 capability done_when 同步要求嚴格 schema
- v0.21.0：design source 從「raw package 直讀」升級為「summary-first + hash-cached」 — `scripts/workflows/ingest-design-source.sh` 把 `constitution.design_source` 指向的 raw package 收斂為 `docs/design/source-summary.md` + `source-tree.txt` + `design-source.yaml` 三件式並寫 SHA-256 sentinel；新 `design_source_ingest` shell-only capability 與自宿主憲法 allowed_capabilities 同步落地；`schemas/workflows/project-spec-pipeline.yaml` 插入 `ingest_design_source` step（pipeline 升為 16 步），UI step done_when 改為**優先**對齊 `docs/design/source-summary.md`（summary-first），raw package 降為 fallback；`schemas/handoff-ticket.schema.yaml` `design_assets_pointer` 描述同步去除 project_id 等於 package 的舊假設；新增 `tests/scripts/test-design-source-ingest.sh`（6 cases / 21 assertions：no_design_source / type=none / rebuilt / cached / source 修改 rebuild / source_path 缺失 halt）；smoke-per-stage 升為 10 step / 136 assertions 全綠
- v0.20.1：把 v0.20.0 的 `--design-package` 旗標從 engine 接通到 wrapper、usage 與下游 workflow YAML — `scripts/cap-workflow.sh` 補 `--design-package` 解析與 forwarding（v0.20.0 只在 `engine/design_prompt.py` 加旗標的斷層）；`scripts/cap-entry.sh` 主用法新增 `cap workflow run --design-package <name>` 推薦寫法；`schemas/workflows/project-constitution.yaml` / `project-spec-pipeline.yaml` 的 design source 舊語意更新為「優先讀 `constitution.design_source.source_path`，多 package 優先用 `--design-package`」；新增 `tests/scripts/test-cap-workflow-design-package-forwarding.sh` wrapper 層 smoke（4 cases / 5 assertions：usage / 不報 unknown option / pkg-a forward / pkg-b 換值不 hard-code）；`tests/e2e/fixtures/token-monitor-minimal/` 補 `design_source: type: none` 對齊新 schema 規範；smoke-per-stage 升為 9 step / 115 assertions 全綠
- v0.20.0：design source 從「以 project_id 隱式推導」升級為「以憲法 design_source block 顯式記錄 + ~/.cap/designs/ 多 package registry」 — `engine/design_prompt.py` 加 `--design-package <name>` 旗標與多候選互動選擇；`schemas/project-constitution.schema.yaml` 新增 optional `design_source` block（type enum 含 `none` / `local_design_package` / `claude_design` / `figma_mcp` / `figma_import_script` + design_root/package/source_path/mode）；`scripts/workflows/bootstrap-constitution-defaults.sh` 在 bootstrap 引導加 design_source 三範例；`engine/step_runtime.py` 升級 `_design_source_path` 為「constitution → design_root+package → legacy fallback」三段式解析；`schemas/design-source-templates.yaml` local-design 模板擴出 `design_package_name` 欄位 + 完整 design_source YAML 區塊供 supervisor 直接複製；`tests/scripts/test-design-source-resolution.sh` 新增 9 case / 15 assertion 跨整鏈驗證（從 registry 端到 constitution 解析端）；`tests/scripts/test-persist-task-constitution.sh` 加 Case 6 補 normalize 別名展開測試（task_summary → goal、user_intent_excerpt → source_request、target_capability → capability），重現並封住 2026-04-30 cap workflow run 觀察到的 supervisor draft 形狀；smoke-per-stage 升為 8 step、110 assertions 全綠
- v0.19.6：deterministic e2e 覆蓋層落地 — 新增 `tests/e2e/` 目錄三件式：(1) `fixtures/token-monitor-minimal/` 最小 CAP 專案 fixture（`.cap.constitution.yaml` + `.cap.project.yaml` + README），repo 追蹤確保跨環境可重跑；(2) `test-project-spec-pipeline-deterministic.sh` 模擬 task_constitution_draft → persist → emit × 6 → seq 遞增重跑驗證的完整鏈路（4 stages / 40 assertions）；(3) `test-ticket-consumption.sh` 透過新增的 `scripts/workflows/fake-sub-agent.sh`（讀 ticket → schema validation → 寫 Type D 符合 handoff-ticket-protocol §4 的五段結構）驗證成功 / 模擬失敗 / 壞 ticket / 缺 env 共 4 cases / 22 assertions，同時 sha256 比對證實 ticket bytes 經 consumption 後不變（read-only 契約）；`smoke-per-stage.sh` 整合為 7 個 step（3 binding + 2 unit smoke + 2 e2e），本 repo 環境下 7/7 PASS、總計 90+ assertions 通過；明確不取代真實 `cap workflow run` AI smoke（仍需使用者環境跑）
- v0.19.5：smoke wrapper 全環境可用基線 — `scripts/workflows/smoke-per-stage.sh` 在 cap 未安裝的環境（CI 新 checkout / 沒裝 cap installer 的開發環境）原本三條 binding 檢查全 graceful skip，現改為先試 cap 再 fallback 用 `bash ${REPO_ROOT}/scripts/cap-workflow.sh`（用 `-f` 不靠 executable bit）；bind 結果偵測改用 canonical `binding_status: ready` 信號 + `required_unresolved=0` 雙重確認，避免被 summary 行裡 `required_unresolved=0` 的 key 名誤觸發 FAIL；CHANGELOG `Deferred` 區塊明示 cap workflow run e2e、sub-agent ticket consumption e2e、engine route_back 自動 enforce 三項仍需 runtime 環境驗證或 engine 程式碼變動，明確標記為下個 cycle 工作；本 repo 環境下 smoke 套件從「2 passed, 3 skipped」變為「5 passed, 0 failed, 0 skipped」
- v0.19.4：把 v0.19.3 的「規範完整 + smoke 全綠」推到「驗證強度與文件可追蹤性」這一層 — `engine/step_runtime.py` 新增 `validate-jsonschema` generic alias subcommand（委派既有 `validate-constitution` 同一個 jsonschema 4.x + manual fallback validator），`scripts/workflows/persist-task-constitution.sh` / `emit-handoff-ticket.sh` 接入「inline minimal pre-write + post-write full schema validation」雙層；`schemas/task-constitution.schema.yaml` / `handoff-ticket.schema.yaml` 從 legacy `fields:` 風格轉為 JSON-Schema 標準（與 `project-constitution.schema.yaml` 同一慣例）；新增 `scripts/workflows/smoke-per-stage.sh` 一鍵 wrapper（三條 cap workflow bind + 兩個 fixture 套件，cap CLI 不在 PATH 時 graceful skip）；`docs/cap/ARCHITECTURE.md` 「Handoff Ticket 欄位參考」、`docs/cap/SKILL-RUNTIME-ARCHITECTURE.md` draft 清單、`docs/cap/IMPLEMENTATION-ROADMAP.md` Phase 0 缺口清單三檔同步反映 v0.19.x 進度，避免文件與實作漂移
- v0.19.3：smoke test 全綠穩定基線——`scripts/workflows/emit-handoff-ticket.sh` 修正 target_step_id 自動推導 edge case（先前未設 `CAP_TARGET_STEP_ID` 與 `CAP_WORKFLOW_STEP_ID` 時，本地預設 fallback 值會誤觸發 derive 把 target 設為 `handoff`，遮蔽 missing-env 錯誤訊號）；改為顯式檢查 `CAP_WORKFLOW_STEP_ID` 是否 set 才允許 derive；fixture smoke 測試套件由 27/28 變為 28/28 PASS（persist 13/13 + emit 15/15），標誌 cap workflow executor 進入可進入實戰測試的穩定狀態
- v0.19.2：把 v0.19.1 的 executor 推到「真的可跑」狀態 — `persist-task-constitution.sh` 修四個阻擋執行的真實 bug（Python f-string 反斜線、FD 3 未開啟、printf `-` 開頭格式）並補 `execution_plan` / `governance` 結構驗證；`emit-handoff-ticket.sh` 補 ticket 寫入前的 12+ field-presence 結構驗證並新增從 `CAP_WORKFLOW_STEP_ID` (emit_<step>_ticket 模式) 自動 derive `target_step_id` 的 fallback；三條 per-stage workflow 在每個 sub-agent step 前插入 `emit_<step>_ticket` 顯式 shell step（spec 9→15 步、impl 9→15 步、qa 6→9 步）使 ticket emission 成為 cap CLI 可觀察一級事件；新增 `tests/scripts/` fixture smoke 測試套件涵蓋兩個 executor 共 9 cases / 28 assertions；自宿主 `.cap.constitution.yaml` 補 `task_constitution_persistence` 至 allowed_capabilities；`agent-skills/01-supervisor-agent.md` §3.7 對齊 init step 拆步並補 RuntimeBinder/step_runtime 責任邊界一段，與 §1.3 / handoff-ticket-protocol.md 三檔完全一致
- `version-control` v7 收斂為單一 workflow + strategy，三段 pipeline 為 `vc_scan` (shell) → `vc_compose` (AI / devops) → `vc_apply` (shell)，shell 不再猜 commit 語意、AI 不再重跑 git，`vc-apply.sh` 的出口 lint 強制 subject 引用 path token、禁用抽象主動詞、annotation 採 `<tag> — <summary>` 格式
- `cap release-check` 可檢查最近或全部 release metadata，阻擋 `Release vX.Y.Z`、單純版本號與泛用 CHANGELOG 條目留在正式發版紀錄中
- 同一份 `agent-skills/` 供 CrewAI、Claude Code、Codex 共用
- CAP 的目標 sub-agent 抽象是 CAP Agent Session，不綁死 Codex 或 Claude 的原生 subagent 能力
- `schemas/workflows/` 只保留內建模板，不承載 task-scoped runtime workflow
- `cap workflow constitution / compile / run-task` 會把 task constitution、compiled workflow、binding report 寫入 `.cap`
- `cap workflow run / run-task` 會在每次前景執行中產出 `agent-sessions.json` 與 `result.md`
- Workflow 定義位於 `schemas/workflows/`，不會同步成 `.agents/skills/` alias
- Trace 預設雙寫到 `~/.cap/projects/<project_id>/traces/`
- 正式產物應進 repo；執行中產物預設留在 CAP storage
- `.cap.constitution.yaml` 是 repo 級正式來源；`~/.cap/projects/<project_id>/constitutions/` 則是 task-scoped snapshot

## Links

- 平台目標：[docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)
- 完整實現路線：[docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)
- 架構文件：[docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)
- Agent 清單：[AGENTS.md](AGENTS.md)
- Workflow 清單：[workflows/README.md](workflows/README.md)
- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>

## License

UNLICENSED — Portfolio 專用，保留一切權利。
