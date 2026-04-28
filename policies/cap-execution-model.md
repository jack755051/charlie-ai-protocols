# CAP Execution Model

本文件定義 CAP 平台、`.cap` 產物倉、專案 repo、constitution、workflow 與一次性 agent session 的責任邊界。

## 1. 分層

CAP 不是單一 agent，而是 workflow runtime 與治理平台。

| Layer | 位置 | 生命週期 | 職責 |
|---|---|---|---|
| CAP platform | `~/.charlie-ai-protocols` 或本 repo | 長期 | 提供 agent prompts、workflow templates、schemas、runtime scripts |
| Project repo | 個別產品 repo | 長期 | 保存產品程式碼、專案文件、repo-local CAP 設定 |
| `.cap` project store | `~/.cap/projects/<project_id>/` | 長期/中期 | 保存 constitution、compiled workflows、bindings、runs、reports、artifacts |
| Workflow run | `.cap/projects/<project_id>/runs` 或 reports | 單次任務 | 保存 execution plan、runtime state、agent sessions、結果報告 |
| Agent session | run 內的 ephemeral worker | 單次 step 或單次任務 | 執行具體 capability，輸出 artifact / handoff |

## 2. Constitution 與 Result

CAP 應區分長期規範與單次結果：

- **B: Constitution**：描述專案目標、限制、使用者規範、允許 agent、executor policy 與 artifact policy。
- **D: Result report**：描述本次執行做了什麼、產出哪些 artifact、哪些 agent session 參與、成功或失敗原因。

建議保存位置：

```text
~/.cap/projects/<project_id>/
  constitutions/
    project-constitution.md
    project-constitution.json
  reports/
    workflows/<workflow_id>/<run_id>/
      run-summary.md
      runtime-state.json
      agent-sessions.json
      result.md
```

## 3. Agent Session

CAP 的 sub agent 不應綁死 Claude 或 Codex 的專屬能力。CAP 應使用自己的抽象：

> Agent session = CAP runtime 根據 role / capability / prompt / inputs 啟動的一次性 worker session。

Provider adapter 可對應：

- Claude：`claude -p`、Claude Code subagent 或其他 Claude runtime。
- Codex：`codex exec`、本機 Codex CLI 或未來 provider adapter。
- CrewAI / LangGraph：未來 graph runtime。

workflow 不直接依賴 provider 細節，只宣告 capability、agent role、executor 與 lifecycle。

## 4. Lifecycle

一次 workflow run 的生命周期：

```text
intake → constitution → compile plan → bind agents → run sessions → validate artifacts → archive result → recycle sessions
```

回收不是刪除 agent 定義，而是：

- 將 session 狀態標記為 `completed` / `failed` / `cancelled` / `recycled`
- 保留 constitution、result report 與 promoted artifacts
- 依 policy 刪除 scratch、temp prompt、raw logs 或大型中間檔

## 5. Deterministic First

CAP runtime 應遵守：

> Deterministic-first, AI-on-ambiguity, halt-on-risk.

也就是可重複、可驗證、低語意判斷的步驟優先交給 shell / script / parser；只有語意不明、跨檔推理、例外診斷或政策允許的 fallback 才交給 AI。

具體選擇規則見 `policies/workflow-executor-selection.md`。
