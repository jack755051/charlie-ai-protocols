# AI Agent Skills Registry (系統大腦中樞)

## 架構藍圖 (System Blueprint)

本系統採用「流水線協作」與「橫向品質監控」雙軌架構：

```text
docs/agent-skills/
├── 00-core-protocol.md         (👑 全域憲法：第一優先讀取)
├── 01-supervisor-agent.md      (🧠 PM/大腦：負責拆解需求與任務發包)
├── 90-watcher-agent.md         (🔍 監控員：橫向稽核，確保各 Agent 產出一致)
│   --- (以下為實作階段) ---
├── 02-sa-standard.md           (📐 SA 系統架構：邏輯、DB Schema、API 契約)
├── 03-ui-standard.md           (🎨 UI 設計師：設計系統、Design Tokens)
├── 04-frontend-standard.md      (💻 前端工程師：Angular/Next/Nuxt 開發)
├── 05-backend-standard.md       (⚙️ 後端工程師：.NET/NestJS 開發)
│   --- (以下為收尾階段) ---
├── 06-devops-standard.md        (🛠️ DevOps 管家：Git、Docker、CI/CD)
└── 99-logger-agent.md           (📝 書記官：紀錄 Changelog)