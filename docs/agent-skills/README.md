# AI Agent Skills Registry (系統大腦中樞)

## 架構藍圖 (System Blueprint)

本系統採用「流水線協作」與「橫向品質監控」雙軌架構：

```text
docs/agent-skills/
├── 00-core-protocol.md          (👑 全域憲法：第一優先讀取)
├── 01-supervisor-agent.md       (🧠 PM/大腦：負責拆解需求與任務發包)
│
│   --- 設計與實作階段 ---
├── 02-techlead-agent.md         (🧭 Tech Lead：技術評估、架構細化、派發建議)
├── 02a-ba-agent.md              (📋 BA 業務分析：流程可視化、邏輯邊界)
├── 02b-dba-api-agent.md         (📐 DBA/API 架構：DB Schema SSOT、API 契約)
├── 03-ui-agent.md               (🎨 UI 設計師：設計系統、第一層設計資產)
├── 12-figma-agent.md            (🖼️ Figma 同步：將設計資產同步至 Figma)
├── 09-analytics-agent.md        (📈 產品分析師：KPI、埋點規格、A/B Test)
├── 04-frontend-agent.md         (💻 前端工程師：Angular/Next/Nuxt 開發)
├── 05-backend-agent.md          (⚙️ 後端工程師：.NET/NestJS 開發)
│
│   --- 維護與排查階段 ---
├── 10-troubleshoot-agent.md     (🔧 故障排查：全棧根因分析、修復調度)
│
│   --- 品質門禁階段 ---
├── 90-watcher-agent.md          (🔍 監控員：橫向稽核，確保各 Agent 產出一致)
├── 08-security-agent.md         (🛡️ 安全審查：與 Watcher 同步執行安全掃描)
├── 07-qa-agent.md               (🧪 QA 工程師：E2E 測試與壓力測試)
├── 11-sre-agent.md              (📊 SRE 專家：效能瓶頸診斷與優化)
│
│   --- 收尾與部署階段 ---
├── 06-devops-agent.md           (🛠️ DevOps 管家：Docker、CI/CD)
├── 99-logger-agent.md           (📝 書記官：紀錄 Devlog 與 Changelog)
│
│   --- 框架與工具策略 ---
└── strategies/
    ├── frontend-angular.md      (Angular 特化規範)
    ├── frontend-nextjs.md       (Next.js 特化規範)
    ├── frontend-nuxtjs.md       (Nuxt.js 特化規範)
    ├── backend-nestjs.md        (NestJS 特化規範)
    ├── backend-dotnet.md        (.NET 特化規範)
    ├── qa-playwright.md         (Playwright E2E 策略)
    ├── qa-k6.md                 (k6 壓測策略)
    ├── unit-test-frontend.md    (前端單元測試策略)
    └── unit-test-backend.md     (後端單元測試策略)
```

## 流水線流程 (Pipeline Flow)

```text
使用者需求 → [01 PM] PRD 產出
  → [02 Tech Lead] 技術執行計畫 (TechPlan)
  → [02a BA] 業務流程規格
  → [02b DBA] Schema SSOT + API 介面規格
  → [03 UI] 設計規格 + 第一層設計資產
  → (若使用者要求) [12 Figma] 同步到 Figma
  → [09 Analytics] KPI + 埋點規格
  → [04 Frontend] / [05 Backend] 實作 + Unit Test
  → [90 Watcher] + [08 Security] 同步稽核
  → [07 QA] 功能驗證 + 壓力測試
  → (若未達標) [11 SRE] 效能優化
  → [06 DevOps] 容器化 + CI/CD 部署
  → [99 Logger] 開發日誌與 Changelog 紀錄
```
