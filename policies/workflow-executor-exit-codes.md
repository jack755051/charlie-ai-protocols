# Workflow Executor Exit Code Contract

本文件定義 `executor: shell` step 與 workflow executor 之間的退出碼契約。目標是讓機械性、低風險步驟可由 shell 快速完成，並只在語意不明、政策衝突或工具失敗時回流 AI。

## 原則

- shell script 必須輸出足以審計的 stdout/stderr；即使失敗，也要說明目前狀態、判定理由與建議路由。
- shell script 不應硬猜語意邊界；無法安全判定時，應回傳可分類的退出碼，讓 executor 決定是否 AI fallback。
- sensitive risk 必須直接 halt，不得交給 AI fallback 自行嘗試加入、提交或推送。
- YAML 只能引用 repo 內白名單 script 路徑；不得在 workflow 內嵌任意 shell 程式碼。

## Exit Codes

| Code | Condition | 語意 | Executor 行為 |
|---:|---|---|---|
| `0` | `success` | shell step 已完成並產出有效內容 | 登記 artifact，繼續下一步 |
| `10` | `no_changes` | 沒有可提交或可處理的變更 | 視為成功 no-op，登記 artifact |
| `20` | `ambiguous_change_type` | 變更類型無法安全判定 | 若 workflow fallback 允許，交給 AI；否則 halt |
| `21` | `mixed_change_type` | 同次變更同時符合多種 commit type | 若 workflow fallback 允許，交給 AI 拆 commit 或選主要 type；否則 halt |
| `30` | `policy_blocked` | detached HEAD、受保護分支、未允許的分支策略等政策阻塞 | 預設 halt；只有 workflow 明確允許才 fallback |
| `40` | `git_operation_failed` | git 指令、hook、push 或檔案操作失敗 | 若 workflow fallback 允許，交給 AI 診斷或重試；否則 halt |
| `50` | `sensitive_file_risk` | 偵測到 `.env`、私鑰、credential 等敏感檔案風險 | 直接 halt，不得 fallback |

## Fallback Policy

workflow step 可用 `fallback.when` 明確宣告哪些條件可交給 AI：

```yaml
fallback:
  executor: ai
  when:
    - ambiguous_change_type
    - mixed_change_type
    - git_operation_failed
```

`shell_exit_nonzero` 可作為廣義 fallback 條件，但不得覆蓋 `sensitive_file_risk`。若需要讓 `policy_blocked` fallback，必須明確列出 `policy_blocked`，避免 shell 將分支治理問題交給 AI 自行繞過。

## Script Output Requirements

每支 shell script 至少應輸出：

- `step_id`
- `status` 或 `condition`
- 掃描到的關鍵證據，例如 `git status --short`、`git diff --stat`
- 已執行或未執行的副作用
- 建議的下一步或 fallback 原因

這份契約屬於 runtime / workflow 層的工程政策。`00-core-protocol.md` 只保留高層治理原則，具體退出碼與執行細節以本文件為準。
