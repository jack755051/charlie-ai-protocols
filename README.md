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

## At A Glance

| 元件 | 位置 | 用途 |
|---|---|---|
| Agent Skills | `docs/agent-skills/` | 角色 prompt SSOT |
| Policies | `docs/policies/` | Git、storage、README 治理等跨工具規範 |
| Workflows | `schemas/workflows/` | 固定流程定義與 workflow schema |
| Capabilities | `schemas/capabilities.yaml` | capability 契約 SSOT |
| Engine | `engine/` | CrewAI 與 workflow loader |
| CLI Scripts | `scripts/` | `cap` 子命令與 wrapper |
| Runtime Storage | `~/.cap/projects/<project_id>/` | traces、drafts、reports、sessions |

架構細節請看 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## Quick Start

安裝：

```bash
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
cap list
cap workflow list
cap workflow ps
cap workflow show version-control-private
cap workflow plan version-control-private
cap workflow run --dry-run workflow-smoke-test "test"
cap workflow run version-control-private "請針對目前變更建立 commit"
```

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
- `run`：有 prompt 時進入前景執行；沒有 prompt 時會先詢問或只顯示 plan
- `run --dry-run`：只顯示執行計畫，不真的執行 step

Workflow 清單請看 [schemas/workflows/README.md](schemas/workflows/README.md)。

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

目前內建 workflow 包含：

- `feature-delivery.yaml`：完整功能交付流程
- `readme-to-devops.yaml`：README 治理到 DevOps 基線
- `version-control-private.yaml`：私人專案版本控制流程
- `version-control-company.yaml`：公司專案最小版本控制流程
- `workflow-smoke-test.yaml`：workflow CLI 與 capability binding 的煙霧測試

相關入口：

- [schemas/workflows/README.md](schemas/workflows/README.md)
- [schemas/workflows/workflow-schema.md](schemas/workflows/workflow-schema.md)
- [schemas/capabilities.yaml](schemas/capabilities.yaml)

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
│   └── handoff-ticket.schema.yaml
├── engine/
├── scripts/
├── AGENTS.md
├── CLAUDE.md
├── Makefile
├── repo.manifest.yaml
└── .cap.agents.json
```

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

- 最新 release：`v0.5.0`
- 同一份 `docs/agent-skills/` 供 CrewAI、Claude Code、Codex 共用
- Workflow 定義位於 `schemas/workflows/`，不會同步成 `.agents/skills/` alias
- Trace 預設雙寫到 `~/.cap/projects/<project_id>/traces/`
- 正式產物應進 repo；執行中產物預設留在 CAP storage

## Links

- 架構文件：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Agent 清單：[AGENTS.md](AGENTS.md)
- Workflow 清單：[schemas/workflows/README.md](schemas/workflows/README.md)
- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>

## License

UNLICENSED — Portfolio 專用，保留一切權利。
