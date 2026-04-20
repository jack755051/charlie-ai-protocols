# Strategy: Lighthouse Audit (v1.0)

> 本文件定義 Lighthouse 作為前端非功能性驗證工具的共通規範。它不是單一 Agent 的專屬領域，而是供 `01 / 07 / 10 / 11 / 99` 共同引用的工具型 SSOT。

## 1. 角色定位與責任分工 (Ownership)

- **QA (07)**：Lighthouse 的主執行者。負責依規範跑出報告、比對門檻並標記結果。
- **SRE (11)**：效能失敗的主分析者。當結果屬 `Performance`、`Core Web Vitals`、資源載入或快取問題時，由你主責解讀與提出優化方案。
- **Troubleshoot (10)**：異常診斷者。當 Lighthouse 結果出現環境差異、不可重現、退化來源不明或結果飄移時，由你主責 RCA。
- **Supervisor (01)**：流程調度者。決定何時觸發 Lighthouse、失敗後該回派哪個角色。
- **Logger (99)**：紀錄者。負責歸檔報告路徑、分數摘要、失敗分類與最終處置。

## 2. 觸發時機 (When to Run)

- **預設觸發條件**：
  - Frontend (04) 完成主要頁面、關鍵 route 或重要 UI 重構後。
  - QA (07) 已完成基本行為驗證，準備進入前端非功能性門禁時。
- **建議涵蓋對象**：
  - 首頁 / Landing Page
  - 主要轉換頁（如登入、註冊、結帳、結算、搜尋）
  - SEO / Accessibility 敏感頁面
- **可略過情境**：
  - 純 API 模組、無前端頁面變更的任務
  - 僅修改後端邏輯且未影響頁面輸出、meta、bundle 或資產載入

## 3. 執行方式與輸出規範 (Execution & Outputs)

### 3.1 執行模式
- **預設 profile**：至少執行一次 `mobile`。若頁面屬桌面主導型產品，可追加 `desktop` 作補充。
- **環境優先序**：
  1. 可穩定重現的 preview / staging URL
  2. 本地開發環境（若 URL 與資源載入條件足夠穩定）
- **結果穩定性**：若單次結果波動過大，至少應重跑 2-3 次確認是否為偶發噪音。

### 3.2 輸出檔案
- **存檔目錄**：`workspace/history/lighthouse/`
- **建議命名**：
  - JSON：`<module>_<page>_<profile>_lighthouse_<YYYYMMDD-HHMMSS>.json`
  - HTML：`<module>_<page>_<profile>_lighthouse_<YYYYMMDD-HHMMSS>.html`
- **最低產出**：
  - 一份可機器讀取的 JSON 報告
  - 一份可供人工檢視的 HTML 報告

### 3.3 最低摘要欄位
每次執行後，至少整理出：
- `target_url`
- `profile`（mobile / desktop）
- `performance`
- `accessibility`
- `best_practices`
- `seo`
- `top_failing_audits`
- `recommended_owner`
- `report_paths`

## 4. 門檻與失敗分類 (Thresholds & Failure Classes)

### 4.1 建議門檻
- **Performance**：`>= 80`
- **Accessibility**：`>= 90`
- **Best Practices**：`>= 90`
- **SEO**：`>= 85`

> 若專案屬內網工具、純後台系統或非 SEO 導向產品，可由 `01` 在交接單中下修 `SEO` 權重，但不得靜默忽略 `Accessibility`。

### 4.2 失敗分類
- **`[LH_PERF_FAIL]`**：Performance / Core Web Vitals / bundle / render-blocking / caching 問題
- **`[LH_A11Y_FAIL]`**：Accessibility 問題，如缺 label、語意錯誤、對比不足、焦點流程異常
- **`[LH_BP_FAIL]`**：Best Practices 問題，如不安全資源、前端配置異常、瀏覽器最佳實踐違規
- **`[LH_SEO_FAIL]`**：SEO / metadata / crawlability 問題
- **`[LH_ENV_UNSTABLE]`**：同頁面結果波動過大、環境差異明顯、資源載入不穩定

## 5. 路由規則 (Routing Rules)

- **若為 `[LH_PERF_FAIL]`**：
  - 由 `01` 轉派 `11-SRE`
  - 若問題顯然位於前端 bundle、圖片、hydration 或 lazy loading，也可同步要求 `04-Frontend` 配合修復
- **若為 `[LH_A11Y_FAIL]` / `[LH_BP_FAIL]` / `[LH_SEO_FAIL]`**：
  - 由 `01` 回派 `04-Frontend`
- **若為 `[LH_ENV_UNSTABLE]`**：
  - 由 `01` 轉派 `10-Troubleshoot`
- **若結果全數達標**：
  - 由 `99` 記錄報告摘要與路徑，納入 devlog / trace

## 6. 記錄摘要格式 (Logging Summary)

提供給 `99-Logger` 的摘要建議至少包含：

```text
【Lighthouse 摘要】
🔦 target_url: [頁面 URL]
🔦 profile: [mobile / desktop]
🔦 scores:
   - performance: [0-100]
   - accessibility: [0-100]
   - best_practices: [0-100]
   - seo: [0-100]
🔦 failure_class: [LH_PERF_FAIL / LH_A11Y_FAIL / LH_BP_FAIL / LH_SEO_FAIL / LH_ENV_UNSTABLE / PASS]
🔦 top_failing_audits: [列出 3-5 個關鍵失敗項]
🔦 recommended_owner: [04 / 10 / 11 / none]
🔦 report_paths:
   - json: [workspace/history/lighthouse/...json]
   - html: [workspace/history/lighthouse/...html]
```
