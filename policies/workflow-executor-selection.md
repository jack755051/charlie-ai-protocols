# Workflow Executor Selection Policy

本文件定義 workflow step 如何選擇 `shell`、`ai`、`fallback` 或 `halt`。

核心原則：

> Deterministic-first, AI-on-ambiguity, halt-on-risk.

## 1. 使用 shell 的條件

step 應優先使用 `executor: shell`，當且僅當：

- 操作可重複執行，且成功條件可由 exit code / structured output 驗證。
- 輸入資料結構明確，例如 git status、manifest、JSON、YAML、檔案路徑清單。
- 失敗可被分類，例如 `no_changes`、`mixed_change_type`、`git_operation_failed`。
- 操作不需要語意推理或只需要低風險規則判斷。
- script 可被限制在 repo 內白名單路徑，例如 `scripts/workflows/*.sh`。

範例：

- git status / diff / commit / tag / push 的 happy path
- manifest 檢查
- schema validation
- formatting / lint / test runner
- artifact promotion / copy

## 2. 使用 AI 的條件

step 應使用 `executor: ai`，當：

- 需求本身模糊，需要補全假設或拆解方案。
- 需要語意判斷，例如 commit 分組、PRD 產出、架構決策、跨文件一致性分析。
- shell 已回報可 fallback 的分類，例如 `ambiguous_change_type`。
- 需要生成自然語言 artifact，例如 PRD、TechPlan、交接摘要、審查報告。

AI step 必須接收最小足夠上下文，不應重新讀完整 repo 或重跑無關流程。

## 3. 使用 fallback 的條件

shell step 可宣告：

```yaml
fallback:
  executor: ai
  when:
    - ambiguous_change_type
    - mixed_change_type
    - git_operation_failed
```

fallback 必須是明確 opt-in。`shell_exit_nonzero` 可作為廣義 fallback，但不得覆蓋 sensitive risk。

## 4. 必須 halt 的條件

step 必須停止，不得自動 fallback，當：

- 偵測 sensitive file risk，例如 `.env`、private key、credential。
- destructive operation 未獲明確授權，例如 `git reset --hard`、force push、大量刪除。
- policy blocked 且 workflow 未明確允許 fallback。
- 權限不足且無安全替代路徑。
- artifact 明確回報 `blocked` / `failed`，即使 process exit code 為 0。

## 5. Constitution 欄位建議

project constitution 可保存 executor policy：

```yaml
executor_policy:
  default: deterministic_first
  use_shell_when:
    - operation_is_repeatable
    - inputs_are_structured
    - success_can_be_validated_by_exit_code
    - failure_can_be_classified
  use_ai_when:
    - semantic_judgment_required
    - requirements_are_ambiguous
    - cross_file_reasoning_required
    - shell_exit_condition_allows_fallback
  halt_when:
    - sensitive_file_risk
    - destructive_operation
    - policy_blocked_without_explicit_override
```
