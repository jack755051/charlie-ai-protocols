# AI Agent Skills Registry (系統大腦中樞)

## 架構藍圖 (System Blueprint)

本系統採用「流水線協作」與「橫向品質監控」雙軌架構：

```text
docs/agent-skills/
├── 00-core-protocol.md          (👑 全域憲法：第一優先讀取)
├── 01-supervisor-agent.md       (🧠 PM/大腦：負責拆解需求與任務發包)
│
│   --- 設計與實作階段 ---
├── 02-sa-standard.md            (📐 SA 系統架構：邏輯、DB Schema、API 契約)
├── 03-ui-standard.md            (🎨 UI 設計師：設計系統、Design Tokens)
├── 04-frontend-standard.md      (💻 前端工程師：Angular/Next/Nuxt 開發)
├── 05-backend-standard.md       (⚙️ 後端工程師：.NET/NestJS 開發)
│
│   --- 品質門禁階段 ---
├── 90-watcher-agent.md          (🔍 監控員：橫向稽核，確保各 Agent 產出一致)
├── 08-security-standard.md      (🛡️ 安全審查：與 Watcher 同步執行安全掃描)
├── 07-qa-standard.md            (🧪 QA 工程師：E2E 測試與壓力測試)
├── 11-sre-optimization-standard.md (📊 SRE 專家：效能瓶頸診斷與優化)
│
│   --- 收尾與部署階段 ---
├── 06-devops-standard.md        (🛠️ DevOps 管家：Docker、CI/CD)
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
    └── qa-k6.md                 (k6 壓測策略)
```

## 流水線流程 (Pipeline Flow)

```text
使用者需求 → [01 PM] PRD 產出
  → [02 SA] 架構規格 + Schema SSOT
  → [03 UI] 設計規格
  → [04 Frontend] / [05 Backend] 實作
  → [90 Watcher] + [08 Security] 同步稽核
  → [07 QA] 功能驗證 + 壓力測試
  → (若未達標) [11 SRE] 效能優化
  → [06 DevOps] 容器化 + CI/CD 部署
  → [99 Logger] 開發日誌與 Changelog 紀錄
```
