# Charlie's AI Protocols (CAP)

> 工業級 AI 多代理協作框架與 CLI 工具。
> 以共享憲法、Agent Skills、Workflow Schema 與 CAP runtime storage，讓多角色 AI 協作可以被標準化、追蹤與重複使用。

![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white)
![CrewAI](https://img.shields.io/badge/CrewAI-1.14+-000000)
![Shell](https://img.shields.io/badge/Shell-Bash%2FZsh-4EAA25?logo=gnubash&logoColor=white)
![Agents](https://img.shields.io/badge/Agents-17-blueviolet)
![Status](https://img.shields.io/badge/status-active-22c55e)

## Purpose

CAP 解決的核心問題是：當多位 AI Agent 共同參與軟體開發流程時，如何維持清楚分工、穩定交接與不可繞過的品質門禁。

它提供四個核心能力：

- Agent Skills：定義 17 位 Agent 的角色邊界與輸出責任
- Core Protocol：以共享憲法統一所有 Agent 的行為準則
- Workflow Schema：把固定流程抽成可重複使用的結構化定義
- CAP CLI：提供安裝、調用、workflow 檢視、trace 與版本管理

## Scope

- In scope：Agent Skills、共享憲法、workflow schema、CrewAI 執行引擎、`cap` CLI、runtime storage 與 README / manifest 治理
- Out of scope：產品業務模組、對外 API 服務、Web UI 與獨立部署中的應用程式邏輯

## Architecture

CAP 採用 shared constitution + specialized agents + workflow schema 的多層架構。
`docs/agent-skills/` 定義角色邊界，`schemas/workflows/` 定義流程契約，`engine/` 負責載入與執行，`scripts/` 提供 `cap` CLI 包裝與本機操作入口，執行期輸出則落到 `~/.cap/projects/<project_id>/`。

## At A Glance

| 元件 | 位置 | 用途 |
|---|---|---|
| Agent Skills | `docs/agent-skills/` | 角色 prompt SSOT |
| Policies | `docs/policies/` | Git、storage、README 治理等跨工具規範 |
| Workflows | `schemas/workflows/` | 固定流程定義與 workflow schema |
| Capabilities | `schemas/capabilities.yaml` | capability 契約 SSOT |
| Engine | `engine/` | CrewAI 與 workflow loader |
| CLI Scripts | `scripts/` | `cap` 子命令與 wrapper |
| Runtime Storage | `~/.cap/projects/<project_id>/` | constitutions、compiled-workflows、bindings、reports、traces |

架構細節請看 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
Skill marketplace 與 runtime binding 草案請看 [docs/SKILL-MARKETPLACE-RUNTIME-DRAFT.md](docs/SKILL-MARKETPLACE-RUNTIME-DRAFT.md)。
Task-scoped workflow compiler 草案請看 [docs/TASK-SCOPED-WORKFLOW-COMPILER-DRAFT.md](docs/TASK-SCOPED-WORKFLOW-COMPILER-DRAFT.md)。
可選的本地 skill registry 範例請看 [.cap.skills.example.yaml](.cap.skills.example.yaml)。

目前狀態：

- `cap workflow plan / bind / run` 已共用 `RuntimeBinder`
- `.cap.skills.yaml` 是 workflow binding 的優先輸入；若缺席，會自動 fallback 到 `.cap.agents.json` legacy adapter
- skill marketplace schema 與遠端 provider 仍屬 draft / 下一階段設計

## Project Structure

```text
charlie-ai-protocols/
├── docs/
│   ├── agent-skills/
│   ├── policies/
│   └── ARCHITECTURE.md
├── schemas/
│   ├── workflows/
│   ├── capabilities.yaml
│   ├── skill-registry.schema.yaml
│   └── task-constitution.schema.yaml
├── engine/
├── scripts/
├── AGENTS.md
├── CLAUDE.md
├── Makefile
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
cap workflow show version-control-private
cap workflow bind version-control-private
cap workflow plan version-control-private
cap workflow constitution "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow compile "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run-task --dry-run "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run --dry-run workflow-smoke-test "test"
cap workflow run version-control-private "請針對目前變更建立 commit"
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
cap workflow plan version-control-private
cap workflow run --dry-run workflow-smoke-test "test"
cap workflow run version-control-private "請針對目前變更建立 commit"
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
- `run --dry-run`：只顯示執行計畫，不真的執行 step

Workflow 清單請看 [docs/workflows/README.md](docs/workflows/README.md)。

## Agent System

目前共 17 位 Agent，分成四類：

- 治理：`01 Supervisor`
- 交付：`02 Tech Lead`、`02a BA`、`02b DBA/API`、`03 UI`、`12 Figma`、`09 Analytics`、`04 Frontend`、`05 Backend`
- 門禁與維運：`90 Watcher`、`08 Security`、`07 QA`、`10 Troubleshoot`、`11 SRE`、`06 DevOps`
- 收尾與輔助：`99 Logger`、`101 README`

完整說明請看：

- [AGENTS.md](AGENTS.md)
- [docs/agent-skills/README.md](docs/agent-skills/README.md)

## Workflow System

Workflow 與 Agent Skills 是並存的兩種使用方式：

- Agent Skill：描述單一角色能做什麼
- Workflow：描述多步驟流程怎麼串接

目前保留中的 workflow 為：

- `workflow-smoke-test.yaml`：workflow CLI 與 capability binding 的煙霧測試
- `readme-to-devops.yaml`：README 治理到 DevOps 基線
- `version-control-private.yaml`：私人專案版本控制主流程
- `version-control-company.yaml`：公司專案最小版本控制流程

其中 `version-control-private.yaml` 是目前收尾主流程：先判定 tag 並同步 `README.md` / `CHANGELOG.md`，再 commit，最後建立 tag。

相關入口：

- [docs/workflows/README.md](docs/workflows/README.md)
- [docs/workflows/workflow-schema.md](docs/workflows/workflow-schema.md)
- [schemas/capabilities.yaml](schemas/capabilities.yaml)
- [schemas/task-constitution.schema.yaml](schemas/task-constitution.schema.yaml)
- [schemas/workflow-run-state.schema.yaml](schemas/workflow-run-state.schema.yaml)

## Workflow Storage Model

workflow 目前分成兩種層級，避免把 runtime 產物塞回主程式 repo：

- `schemas/workflows/*.yaml`
  - 內建 workflow 模板與固定流程範本
  - 屬於 repo 內的可版本化定義
- `~/.cap/projects/<project_id>/constitutions/`
  - 一句話需求推導出的 task constitution snapshot
- `~/.cap/projects/<project_id>/compiled-workflows/`
  - `run-task` 或 `compile` 產生的 task-scoped compiled workflow bundle
- `~/.cap/projects/<project_id>/bindings/`
  - `bind / run / run-task` 實際用到的 binding report snapshot
- `~/.cap/projects/<project_id>/reports/workflows/`
  - 每次執行的 artifact、handoff、runtime state、watchdog log

這代表：

- 主 repo 保留模板、schema、engine、CLI
- 單次任務的 constitution / compiled workflow / binding / run output 都進 `.cap`
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

- 最新已驗證 tag：`v0.10.3`；`version-control-private` 以單一 step 完成 tag 判定、changelog 同步、commit 與 tag
- 同一份 `docs/agent-skills/` 供 CrewAI、Claude Code、Codex 共用
- `schemas/workflows/` 只保留內建模板，不承載 task-scoped runtime workflow
- `cap workflow constitution / compile / run-task` 會把 task constitution、compiled workflow、binding report 寫入 `.cap`
- Workflow 定義位於 `schemas/workflows/`，不會同步成 `.agents/skills/` alias
- Trace 預設雙寫到 `~/.cap/projects/<project_id>/traces/`
- 正式產物應進 repo；執行中產物預設留在 CAP storage

## Links

- 架構文件：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Agent 清單：[AGENTS.md](AGENTS.md)
- Workflow 清單：[docs/workflows/README.md](docs/workflows/README.md)
- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>

## License

UNLICENSED — Portfolio 專用，保留一切權利。
