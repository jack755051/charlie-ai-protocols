# Workflow Executor UX 與 Watchdog 改進草案

> 本文件記錄 `cap-workflow-exec.sh` 的 UX 問題與 watchdog 改進方案。
> 狀態：部分已實作。

## 目前實作狀態

已實作：

- spinner 顯示最新輸出尾行預覽
- spinner 顯示 `silent=<秒數>`，可看出多久沒有新輸出
- step 硬性 timeout，預設 `600` 秒
- step 靜默 stall 偵測，預設 `120` 秒
- workflow step 可設定 `timeout_seconds` / `stall_seconds` / `stall_action`
- timeout 會自動終止該 step；stall 預設只警告，設定 `stall_action: kill` 才會自動終止

可用環境變數：

| 變數 | 預設 | 說明 |
|---|---:|---|
| `CAP_WORKFLOW_STEP_TIMEOUT_SECONDS` | `600` | 全域 step 硬性上限 |
| `CAP_WORKFLOW_STEP_STALL_SECONDS` | `120` | 全域 step 靜默上限 |
| `CAP_WORKFLOW_STALL_ACTION` | `warn` | 靜默達上限時 `warn` 或 `kill` |
| `CAP_WORKFLOW_PREVIEW_CHARS` | `80` | spinner 尾行預覽字元數 |

## 問題描述

目前 workflow executor 在執行 AI step 時，使用者只能看到 spinner 與經過秒數：

```
⠹ Running ba... (214s)
```

三個核心問題：

| 問題 | 影響 |
|---|---|
| **無法得知進度** | AI 輸出被導入暫存檔，使用者完全看不到 step 內部在做什麼 |
| **卡死/無限循環無法察覺** | 只有秒數在跑，無法區分「正常執行中」與「已卡死」 |
| **無法精確終止** | 只能 Ctrl+C 殺整個 workflow，無法 per-step 控制 |

## 改進方案（三層防護）

### 第一層：即時輸出預覽

**解決**：「現在在幹嘛」

把 AI 的輸出從完全靜默改為尾行即時預覽 — spinner 旁邊顯示最新一行輸出的前 60 字元：

```
⠹ Running ba... (214s) │ 正在產出 Bounded Context 切分...
⠸ Running ba... (218s) │ 已完成時序圖，接下來處理狀態機...
```

實作狀態：已實作。

實作要點：

- `run_step` 的輸出同時寫入 `STEP_TMP`（保留完整紀錄）
- spinner 迴圈中以 `tail -1` 讀取最新行，截取前 60 字元顯示
- 使用 `\r\033[K` 清行避免殘影

### 第二層：Step Timeout + 靜默偵測

**解決**：「卡死自動停」

| 機制 | 邏輯 | 預設值 |
|---|---|---|
| **硬性 timeout** | step 執行超過上限後 kill process | 600 秒（10 分鐘） |
| **靜默偵測 (stall)** | `STEP_TMP` 在連續 N 秒內無新增內容，判定為疑似卡住 | 120 秒 |
| **超時處置** | timeout 直接 kill；stall 預設警告，`stall_action=kill` 時才 kill | — |

實作狀態：已實作。

偵測邏輯（在 spinner 迴圈內）：

```bash
# 記錄上次檔案大小
LAST_SIZE="$(wc -c < "${STEP_TMP}")"
LAST_CHANGE="$(date '+%s')"

# spinner 迴圈內
CURRENT_SIZE="$(wc -c < "${STEP_TMP}")"
if [ "${CURRENT_SIZE}" != "${LAST_SIZE}" ]; then
  LAST_SIZE="${CURRENT_SIZE}"
  LAST_CHANGE="$(date '+%s')"
fi

SILENT_DURATION="$(( $(date '+%s') - LAST_CHANGE ))"
if [ "${SILENT_DURATION}" -ge "${STALL_SECONDS}" ]; then
  kill "${STEP_PID}" 2>/dev/null
  # 標記 [STALL]
fi

if [ "${ELAPSED}" -ge "${TIMEOUT_SECONDS}" ]; then
  kill "${STEP_PID}" 2>/dev/null
  # 標記 [TIMEOUT]
fi
```

### 第三層：Workflow YAML 層級設定

在 step 定義中新增可選的超時設定：

```yaml
steps:
  - id: ba
    capability: business_analysis
    timeout_seconds: 600    # 硬性上限，預設 600
    stall_seconds: 120      # 靜默上限，預設 120
    stall_action: warn      # warn 或 kill；預設 warn
```

`workflow-schema.md` 需新增對應欄位定義。

實作狀態：已實作。

## Watcher 的角色邊界

Watcher 是**事後稽核者**，不適合做即時 watchdog：

- Watcher 是 AI agent，本身也需要啟動時間，無法做毫秒級 process 監控
- 超時 kill 是 process signal 層級的操作，屬於 executor 職責
- Watcher 的職責是在 step 完成後檢查產出品質（governance checkpoint），不是監控 process 存活

正確的職責分工：

| 層級 | 負責什麼 | 由誰執行 |
|---|---|---|
| 即時預覽 | 「現在在幹嘛」 | `cap-workflow-exec.sh` spinner 迴圈 |
| Timeout + Stall 偵測 | 「卡死自動停」 | `cap-workflow-exec.sh` watchdog 邏輯 |
| 產出品質檢查 | 「結果對不對」 | Watcher (90) governance checkpoint |

## 實作優先序

1. **P1 — 靜默偵測 + timeout**：最關鍵，防止資源浪費與無限等待
2. **P2 — 即時輸出預覽**：大幅改善 UX，但不影響功能正確性
3. **P3 — workflow YAML timeout 設定**：讓不同 step 可自訂上限

## 相關檔案

- `scripts/cap-workflow-exec.sh`：executor 主體，spinner 迴圈在此
- `schemas/workflows/workflow-schema.md`：step 欄位定義
- `docs/agent-skills/90-watcher-agent.md`：Watcher 職責邊界（不變）
