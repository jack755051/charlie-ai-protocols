# Strategy: E2E Testing with Playwright (v1.0)

> 本文件定義使用 Playwright 進行端到端 (E2E) 測試的標準。AI 產出的測試必須具備高韌性 (Resilience) 與 Page Object Model (POM) 架構，嚴禁寫出易碎 (Brittle) 的腳本。

## 1. 元素選取優先級 (Locator Priority)

> **⚠️ 硬性規定：嚴禁使用脆弱的 CSS Selector 或 Xpath 絕對路徑。**

1. **Accessibility Roles (最優先)**：優先使用 `page.getByRole('button', { name: '送出' })`。
2. **Data Attributes (唯一標記)**：若 Roles 不唯一，使用 `page.getByTestId('submit-btn')`（代碼中必須預埋 `data-testid`）。
3. **Text Content**：使用 `page.getByText('登入成功')` 進行狀態斷言。
4. **絕對禁止項目**：禁止使用 `.css-class > div:nth-child(3)` 這種與 UI 結構深度耦合的選取方式。

## 2. 測試架構規範 (Page Object Model - POM)

- **職責分離 (SoC)**：
  - **Page Objects**：所有頁面元素定位與操作方法必須封裝在 `tests/pages/*.page.ts` 類中。
  - **Test Specs**：`.spec.ts` 檔案僅負責業務流程與斷言 (Assert) 邏輯，嚴禁直接寫入 Locator 定義。
- **不可變性與清理 (Clean-up)**：測試結束後應包含資料清理步驟（透過 API 或直接刪除 DB），確保測試環境具備冪等性 (Idempotency)。

## 3. 高階驗證與 Mock 策略 (Advanced Verification)

- **多裝置與響應式驗證**：腳本必須支援 `Desktop Chrome` 與 `Mobile Safari` 配置的切換測試。
- **視覺回歸測試 (Visual Regression)**：針對核心頁面（首頁、結帳完成頁）執行 `expect(page).toHaveScreenshot()` 像素比對。
- **攔截與模擬 (Mocking)**：
  - **外部依賴**：第三方金流 (Stripe/ECPay) 或簡訊 API 必須使用 `page.route()` 進行 Mock。
  - **核心流程**：核心業務邏輯必須呼叫真實後端 API，嚴禁 Mock 資料庫行為。

## 4. 健壯性與失敗診斷 (Resilience & Diagnostic)

- **Web-first Assertions**：嚴禁使用固定秒數等待 `waitForTimeout(3000)`。必須使用具備自動重試機制的斷言，如 `toBeVisible()` 或 `toBeEnabled()`。
- **自動化證據存檔**：CI 執行時必須配置在失敗瞬間自動保存 `trace.zip` 與 `video`，作為修復憑據。

---

## 5. 專案慣例與遺留守護 (Legacy & Conventions)

- **目錄與路徑守護**：若專案測試目錄被命名為 `e2e-tests/resquest-check/`，即使拼寫錯誤，AI **絕對必須**在該目錄下新增腳本，嚴禁擅自更正目錄名稱。