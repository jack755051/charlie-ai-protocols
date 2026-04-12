# AI Agent Skills Registry (系統大腦中樞)

本目錄存放了驅動專案自動化開發的 Multi-Agent 技能與規範定義檔。

## 架構藍圖 (System Blueprint)

本系統採用流水線 (Pipeline) 協作架構，執行順序與職責劃分如下：

```text
docs/agent-skills/
├── 00-core-protocol.md         (👑 全域憲法：第一優先讀取)
├── 01-supervisor-agent.md      (🧠 PM/大腦：第二步，負責拆解需求)
│   --- (以下為實作階段) ---
├── 02-sa-standard.md           (📐 SA 系統架構：釐清邏輯、DB Schema)
├── 03-ui-standard.md           (🎨 UI 設計師：定義色彩、Token)
├── 04-frontend-standard.md     (💻 前端工程師：Nuxt/Next 開發)
├── 05-backend-standard.md      (⚙️ 後端工程師：NestJS/PostgreSQL 開發)
│   --- (以下為收尾階段) ---
├── 06-devops-standard.md       (🛠️ DevOps 管家：Git、CI/CD)
└── 99-logger-agent.md          (📝 書記官：紀錄 Changelog)
