# Execution Layering — Shell / Python / AI 的職責邊界

> 本文件定義 CAP runtime 的執行分層。Shell、Python 與 AI 不是亂混的關係，而是各自負責不同的工作；本文件把「程式形狀已存在但未明文化」的分層規則固定下來。
> 工程整理優先序與長期 roadmap 以 [IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md) 為主；本文件聚焦於分層職責與邊界判準。

## 1. 為什麼要分層

CAP 是「本機 AI workflow runtime」，每一次 `cap workflow run` 都會經過：

```
使用者輸入
  → CLI 入口
  → workflow plan / binding（資料處理）
  → step 執行（含 git 操作、檔案 I/O、語意判讀）
  → artifact / handoff 寫入
  → 結果報告
```

如果整條鏈都用 shell，JSON / YAML / 結構化驗證會脆弱；如果整條鏈都用 Python，`subprocess` 控制、訊號傳遞、外部 CLI 串接會繁瑣。最終形成的折衷是：**Shell 做系統膠水、Python 做資料邏輯、AI 做語意判讀**。

## 2. 五層分層總覽

| 層 | 主要實作 | 範例檔 | 主要職責 |
|---|---|---|---|
| 1. CLI 入口層 | Shell | `scripts/cap-entry.sh`、`Makefile`、`install.sh` | 解析使用者命令、分派到子 wrapper、安裝/別名/環境檢查 |
| 2. Orchestration 層 | Shell | `scripts/cap-workflow.sh`、`scripts/cap-workflow-exec.sh` | step 排程、subprocess 控制、watchdog（timeout / stall）、AI CLI（codex / claude）啟動、stdout 串流 |
| 3. Python 邏輯層 | Python | `engine/workflow_loader.py`、`engine/runtime_binder.py`、`engine/workflow_cli.py`、`engine/step_runtime.py`、`engine/task_scoped_compiler.py`、`engine/project_context_loader.py` | YAML/JSON 解析、workflow plan / binding、registry / artifact / session ledger、跨平台路徑處理、結構化 lint |
| 4. Shell deterministic step 層 | Shell | `scripts/workflows/vc-scan.sh`、`scripts/workflows/vc-apply.sh` | workflow step 內，直接做 git ops、檔案 scan、deterministic 守門（敏感檔、no_changes、lint） |
| 5. AI step 層 | 由 workflow yaml `executor: ai` 決定 | provider 透過 `codex exec` / `claude -p` 執行 | 語意判讀、規格推導、commit envelope 產出、trade-off 決策 |

層級之間的觸發關係不是固定「Shell 叫 Python」或「Python 叫 Shell」。`schemas/workflows/version-control-private.yaml` 就是混合：`vc_scan` 與 `vc_apply` 是 shell（第 4 層）、`vc_compose` 是 AI（第 5 層），由第 2 層 `cap-workflow-exec.sh` 依 step `executor` 欄位分派。

## 3. 邊界判準

當需要決定一段邏輯該放在哪一層時，依以下判準：

### 留在 Shell（第 1、2、4 層）的情境

- **使用者入口**：alias、PATH、安裝 wrapper。
- **環境變數注入與繼承**：`CAP_WORKFLOW_*` 系列直接傳遞給子進程。
- **外部 CLI 啟動**：`codex exec` / `claude -p`、其他第三方工具。
- **子進程 watchdog**：timeout / stall / signal trap（Python 要用 `subprocess` + `signal` 重新實作，CP 值低）。
- **簡單 git happy path**：`git status --short`、`git diff --stat`、`git add` / `commit` / `push` 等不需複雜邏輯的指令。
- **stdout 串流與分段渲染**：spinner、progress bar、即時 tail。
- **檔案路徑膠水**：`mkdir -p`、`tee`、`cat <<EOF` 之類純粹的 I/O。

### 交給 Python（第 3 層）的情境

- **JSON / YAML parsing**：shell 沒有原生支援，inline `python3 -c` 寫多了會脆弱。
- **workflow plan / binding**：拓撲排序、capability → skill 解析、版本相容性檢查。
- **狀態檔讀寫**：`runtime-state.json`、`agent-sessions.json`、`workflow-runs.json` 的 schema-aware 操作。
- **artifact registry / lineage**：跨 step 傳遞的 artifact metadata。
- **複雜 lint / 結構化驗證**：commit envelope schema 檢查、handoff ticket 欄位驗證、project constitution schema validate。
- **跨平台路徑處理**：`pathlib.Path`、Windows / WSL / macOS 差異。
- **任何需要 try/except 細粒度錯誤處理的邏輯**：shell 的 `set -e` + trap 太粗粒度。

### 交給 AI（第 5 層）的情境

- **commit message / release note 產出**：根據 git diff 推語意。
- **規格推導**：從 prompt 與 repo context 推 task constitution。
- **架構決策**：trade-off 評估、技術選型。
- **錯誤診斷**：複雜失敗情境的 root cause 分析。
- **不可機械化的判斷**：例如「這份 diff 該屬於 feat 還是 refactor」。

## 4. Shell deterministic step 與 AI step 的混合

第 4 層與第 5 層常常在同一個 workflow 內混合，例如：

```yaml
steps:
  - id: vc_scan      # Shell：scan + 守門 + evidence pack
    executor: shell
    script: scripts/workflows/vc-scan.sh

  - id: vc_compose   # AI：根據 evidence 產 commit envelope JSON
    needs: [vc_scan]

  - id: vc_apply     # Shell：lint envelope + git ops
    executor: shell
    script: scripts/workflows/vc-apply.sh
    needs: [vc_compose]
```

關鍵原則：

- **shell 不猜語意**：`vc-scan.sh` 不嘗試從 diff 推 commit subject，只把 evidence 結構化輸出。
- **AI 不重做機械事**：`vc_compose` 收到 evidence pack 就好，不能再去跑 `git status`。
- **shell 出口 lint 守門**：`vc-apply.sh` 拿到 AI 的 envelope 後做硬規則檢查（subject 是否引用 path token、annotation 是否符合格式），lint fail 直接 halt。

這套 shell ↔ AI 切分，把「省 token / 減少非必要 LLM 呼叫」與「品質硬守門」同時達成。

## 5. 目前狀態與過渡項

完整重構與待辦項以 [IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md) 為主。本節只列「分層上仍處於過渡」的項目：

- `scripts/cap-workflow-exec.sh` 是第 2 層中最大的一支（約 1300 行），同時負責 step flatten、prompt 組裝、shell/AI 執行、watchdog、artifact 寫入、handoff、session ledger 與錯誤分類。**長期應逐段瘦身**：
  - 已抽到 Python：runtime registry / session ledger / artifact materialization / plan metadata 解析（`engine/step_runtime.py`）。
  - 仍在 shell：watchdog 主迴圈、subprocess 控制、stdout 串流——這些是 shell 強項，不一定要搬。
- `scripts/sync_claude_agents.py` 是過渡產物，未來應整合進 `scripts/mapper.sh`，由統一入口管理 `.claude/agents/` 與 `~/.agents/skills/` 的同步。
- 第 5 層的 AI provider 目前直接寫死 `codex exec` / `claude -p`，未來透過 `AgentSessionRunner` 抽象化（roadmap Phase 6）。

## 6. 反模式

下列行為是分層被破壞的訊號：

- **shell 內 inline `python3 -c`**：表示 Python 邏輯該抽到 `engine/step_runtime.py` 的 subcommand。CAP 已收斂的範例：`cap-workflow-exec.sh` 與 `cap-registry.sh` 的 heredoc Python 已搬進 `step_runtime.py` 的 `plan-meta` / `parse-input-check` / `registry-list` / `registry-get`。
- **Python 內呼叫複雜 shell pipeline**：表示 shell 那段該整理成 `scripts/workflows/*.sh` 獨立檔，再由 Python 透過 `subprocess.run` 呼叫一次。
- **AI step 內重跑 git**：表示 evidence pack 給得不夠，應該由前置 shell step 補足。
- **shell 在做 commit 語意判讀**：應由 AI step 接手，shell 退回到掃描與守門。

## 7. 對應檔案與 SSOT

- 分層職責：本文件
- workflow schema 與 step 欄位：[../workflows/workflow-schema.md](../workflows/workflow-schema.md)
- shell executor exit code 契約：[../policies/workflow-executor-exit-codes.md](../policies/workflow-executor-exit-codes.md)
- skill registry 與 binding：[SKILL-RUNTIME-ARCHITECTURE.md](SKILL-RUNTIME-ARCHITECTURE.md)
- 平台目標：[PLATFORM-GOAL.md](PLATFORM-GOAL.md)
- 完整實現路線：[IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md)
