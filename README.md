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
  <a href="docs/cap/README.md">📚 Docs Index</a>
  ·
  <a href="docs/cap/ARCHITECTURE.md">Architecture</a>
  ·
  <a href="docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md">Progress</a>
  ·
  <a href="docs/cap/RELEASE-NOTES.md">Release Notes</a>
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

## Status

- **Latest tag**：`v0.22.0-rc10` — close P6 with handoff schema gate and route_back_to control flow
- **Phase 進度**：P0 / P1 / P2 / P3 / P4 / P5 / P6 已完成（其中 P4 #5 source priority resolver 與 P5 #9 stall handling 為 deferred non-blocking）；**P7-P10 pending**
- **單一進度來源**：[docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md](docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md)
- **完整 release 紀錄**：[docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md)

| Protocol Layer | Runtime Surface | Contract |
|---|---|---|
| Constitution | `.cap.constitution.yaml` | repo governance |
| Agent Skills | `agent-skills/` | role boundaries |
| Workflows | `schemas/workflows/` | repeatable execution |
| Storage | `~/.cap/projects/<project_id>/` | traces, reports, bindings |

## Purpose

CAP 想處理的問題是：當多位 AI Agent 共同參與軟體開發流程時，如何把角色分工、交接內容、執行紀錄與常用流程整理成可追蹤的形式。

它提供四個核心能力：

- **Agent Skills**：定義 17 位 Agent 的角色邊界與輸出責任
- **Core Protocol**：以共享憲法統一所有 Agent 的行為準則
- **Workflow Schema**：把固定流程抽成可重複使用的結構化定義
- **CAP CLI**：提供安裝、調用、workflow 檢視、trace 與版本管理

完整目標與設計理念見 [docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)；架構細節見 [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)。

## Install

```bash
bash install.sh

# 或使用遠端安裝腳本
curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
source ~/.zshrc

cap setup
cap sync
```

## Common Commands

```bash
# 平台 / repo state
cap version
cap update latest
cap release-check --recent 10
cap project init
cap project status
cap project doctor

# Workflow 與 task
cap workflow list
cap workflow show version-control
cap workflow plan version-control
cap workflow bind version-control
cap workflow compile "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run-task --dry-run "用 Tauri 做個 AI 額度監控小工具，先不要直接實作"
cap workflow run --strategy auto version-control "版本更新"

# Session ledger（runtime observability）
cap session inspect <session_id>
cap session inspect --run-id <run_id> --json
cap session analyze --top 10                       # 彙整 token/time 熱點分析
cap session analyze --run-id <run_id> --json

# CAP-managed provider session（顯式入口）
cap claude [ARGS...]                               # 走 CAP wrapper 啟動 Claude，記錄 trace
cap codex  [ARGS...]                               # 走 CAP wrapper 啟動 Codex，記錄 trace
```

完整 CLI 入口由 `scripts/cap-entry.sh` 派發；策略 / dry-run / agent-session 等行為以 [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md) 為準。

### Provider Isolation

CAP **不會**預設包裹（hijack）裸 `claude` / `codex`：

- **裸 `claude` / `codex`** — 永遠是原生 provider CLI；在 `~` 或任何非 CAP 目錄呼叫不會觸發 `cap-paths`、`project_id` resolver 或要求 `.cap.project.yaml`。
- **`cap claude` / `cap codex`** — CAP-managed provider 入口；會走 `cap-entry.sh` → `cap-session.sh`，自動寫入 session trace、套用 project_id 解析。
- **舊行為（CAP 包裹原生 CLI）** — 從 v0.22.x 起為 opt-in，`CAP_WRAP_NATIVE_CLI=1 make install` 才會把裸命令重導向 CAP。

理由：global `~/.zshrc` 的 shell function 影響範圍橫跨所有目錄；專案級 runtime 不該預設劫持 provider 命令。詳見 [docs/cap/ARCHITECTURE.md §Provider Isolation](docs/cap/ARCHITECTURE.md#provider-isolation)。

## Usage Modes

### Skill Mode

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

### Workflow Mode

適合固定步驟、依賴明確、需要可重複交付的流程。`cap workflow` 子命令包含 `list / ps / show / inspect / plan / constitution / compile / run-task / run`，並支援 `--strategy fast|governed|strict|auto` 與 `--dry-run`。常用 workflow：

- `workflow-smoke-test`：workflow CLI 與 capability binding 的煙霧測試
- `version-control`：三段 pipeline（vc_scan → vc_compose → vc_apply）+ strategy + lint 守門
- `project-constitution`：從一句話需求產出 Project Constitution

完整 workflow 清單見 [workflows/README.md](workflows/README.md)；版本控制 strategy 與 vc-class executor 規範見 [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)。

## Architecture Overview

CAP 採用 shared constitution + specialized agents + workflow schema 的多層架構：

- `agent-skills/` 定義角色邊界
- `schemas/workflows/` 定義流程契約
- `engine/` 負責載入 / compile / bind / runner
- `scripts/` 提供 `cap` CLI 包裝與本機操作入口
- `~/.cap/projects/<project_id>/` 是 runtime storage（constitutions / compiled-workflows / bindings / reports / traces / sessions）

CAP 區分三種資產：

- **平台內建**：base agent-skills、base workflows、capability contracts、binder / compiler / promote 機制
- **專案來源**：各 repo 自己的 `Project Constitution`、skill registry、workflow definitions
- **Runtime Workspace**：`~/.cap/projects/<project_id>/` 的 snapshot / bindings / traces / reports

執行生命週期、Constitution 模型、Workflow Storage Model、Project Constitution vs Task Constitution 5-surface 分流等細節，請看 [docs/cap/README.md](docs/cap/README.md) index 並依需求進入對應 boundary memo。

## Project Structure

```text
charlie-ai-protocols/
├── agent-skills/                     # Agent 角色 prompt SSOT
├── policies/                         # 跨工具規範（git / storage / readme）
├── schemas/                          # capability 契約 + workflow / runtime contract
│   └── workflows/
├── engine/                           # workflow loader / compiler / binder / session runner
├── scripts/                          # cap CLI wrappers
├── workflows/                        # 已使用中的 workflow 模板
├── docs/cap/                         # 工程文件（見 docs/cap/README.md）
├── tests/                            # bash + python fixtures + e2e
├── .cap.constitution.yaml            # repo 級 Project Constitution
├── .cap.project.yaml                 # 專案 identity / runtime path
├── .cap.skills.example.yaml          # skill registry 範例
└── repo.manifest.yaml                # repo metadata
```

執行期資料寫到：`~/.cap/projects/<project_id>/{constitutions,compiled-workflows,bindings,reports/workflows,traces,sessions}/`

## Interfaces / Dependencies

- **CLI**：主入口為 `scripts/cap-entry.sh` 與 `Makefile`
- **API / Worker / Cron / Web UI**：none
- **Python** ≥ 3.10、**CrewAI** ≥ 1.14、`python-dotenv`、`PyYAML`、Bash / Zsh、GNU Make

選用消費端：

- Claude Code：透過 `@import` 掛載協議
- OpenAI Codex：透過 `$prefix` 與 `cap agent` 使用 Agent Skills

## Links

- 文件總入口：[docs/cap/README.md](docs/cap/README.md)
- 平台目標：[docs/cap/PLATFORM-GOAL.md](docs/cap/PLATFORM-GOAL.md)
- 架構：[docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md)
- 進度（SSOT）：[docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md](docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md)
- 開發路線：[docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md)
- Release 歷史：[docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md)
- Agent 清單：[AGENTS.md](AGENTS.md)
- Workflow 清單：[workflows/README.md](workflows/README.md)
- Portfolio: <https://jack755051.github.io/charlie_portfolio_frontend/portfolio>

## License

UNLICENSED — Portfolio 專用，保留一切權利。
