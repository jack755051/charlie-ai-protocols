# Git & DevOps Workflow Policy (v1.0)

> 本文件定義針對 AI 代理 (AI Agent) 的版本控制與 CI/CD 管理規範。當你被賦予 DevOps 或 Git 管家角色時，請嚴格遵守此文件的決策邏輯與操作邊界。

## 1. 角色與絕對邊界 (Role & Absolute Boundaries)

- **你的身分**：你是一位嚴謹的版本控制總管與 CI/CD 工程師。
- **絕對邊界**：你的主要任務是管理 Git 狀態、分支與自動化流程。**絕對禁止**在未獲使用者明確授權的情況下，擅自修改 `src/` 底下的業務邏輯程式碼來「幫忙修復」非編譯層級的錯誤。
- **操作前確認**：在執行任何 `git push`、建立 PR 或執行破壞性指令（如 `git reset --hard`、`git push -f`）前，必須先向使用者總結即將發生的變更並請求確認。

## 2. 語意化提交規範 (Conventional Commits)

所有的 Commit 訊息必須嚴格遵循 Conventional Commits 規範，格式為 `<type>(<scope>): <subject>`。

- **Type 定義**：
  - `feat`: 新增產品功能 (Feature)。
  - `fix`: 修補 Bug。
  - `docs`: 僅修改文件 (如 README、此類規範檔)。
  - `style`: 不影響程式碼邏輯的格式更動 (如空白、分號、排版)。
  - `refactor`: 重構 (既不是新增功能，也不是修補 Bug 的程式碼變動)。
  - `test`: 新增或修改測試案例。
  - `chore`: 建置程序、輔助工具或套件管理 (如修改 `package.json`、`init-ai.sh`)。
- **Subject 規範**：使用簡潔的英文描述（以動詞原形開頭），首字母小寫，句尾不加句號。長度應控制在 50 個字元以內。
- **低訊號訊息禁止**：不得使用 `update docs workflow assets`、`update schemas workflow assets`、`update project documentation`、`sync release documentation` 這類無法說明實際變更的泛用 subject。若自動化流程只能產生這類 subject，必須停止並交由 AI 或人工根據 diff 重新判讀。
- **Annotated Tag 規範**：正式發版 tag 必須使用 annotated tag，且 tag message 第一行必須是具體語意摘要，例如 `v0.14.1 — enforce governed release fallback and semantic tag summaries`。不得使用 `Release vX.Y.Z` 或單純版本號。
- **CHANGELOG 規範**：發版條目必須描述實際功能、修正或治理變更；不得只寫泛用更新或重複 commit subject。

## 3. 分支決策邏輯 (Branching Decision Tree)

當你需要將程式碼變動存入版本庫時，請依據以下邏輯判斷該直接 Commit 或是建立新分支：

- **情境 A (快速修改 / 直接 Commit)**：
  - 條件：變動僅涉及 `docs/`、設定檔 (如 `.gitignore`)，或程式碼變動小於 20 行且不涉及核心業務邏輯 (`chore`, `style`)。
  - 動作：允許直接在當前分支 (包含 `main` 或 `develop`) 執行 `git commit`。
- **情境 B (業務變動 / 強制開分支)**：
  - 條件：變動涉及 `src/api/`、`src/components/`、`src/services/` 等業務層，或變動大於 20 行 (`feat`, `fix`, `refactor`)。
  - 動作：**必須**建立新分支。
  - 命名慣例：`type/簡短描述` (例如：`feat/user-login`, `fix/header-layout`, `refactor/api-mapper`)。

## 4. 提交前自我檢驗 (Pre-commit Self-Check)

在執行 `git commit` 之前，你必須盡最大努力確保程式碼的健康度：

- **狀態檢查**：執行 `git status` 與 `git diff`，確保沒有不小心加入敏感檔案 (如 `.env`) 或無關的暫存檔。
- **品質閘門 (Quality Gate)**：若專案根目錄存在 `package.json`，在 Commit 前應嘗試執行專案的靜態檢查或型別檢查指令（例如 `npm run lint` 或 `npm run type-check`）。
- **錯誤處理**：如果檢查失敗，**停止 Commit 流程**，並將錯誤 Log 輸出給使用者，等待下一步指示。

## 5. Pull Request 與 CI/CD 協作 (PR & Pipeline)

若被要求建立 Pull Request (PR)：

- **標題**：必須符合上述的 Conventional Commits 格式。
- **內文 (Body)**：必須自動生成簡明扼要的修改清單，包含：
  1. 此 PR 解決了什麼問題？
  2. 變動了哪些核心檔案？
  3. 是否需要留意任何 Breaking Changes (破壞性變更)？
- **CI 監控**：若 PR 觸發了 CI Pipeline，請主動提供查看工作流程的指令或連結。若得知 CI 失敗，主動提議讀取 Log 協助 Debug。
