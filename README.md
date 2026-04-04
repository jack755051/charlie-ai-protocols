# Charlie's AI Protocols

> 這裡是 Charlie 的 AI 輔助開發規則中控台 (AI-driven Workflow Standards)。
> 本 Repo 收錄了跨語言通用的開發紀律、前端架構標準，以及特定框架的實作策略。透過標準化 AI 的上下文 (Context)，確保產出的程式碼高度對齊團隊架構與開發哲學。

## 📂 目錄結構與讀取協議 (Directory Structure & Reading Protocol)

AI 助手在執行任務時，請根據當前專案的性質，**依序讀取**以下文件組合：

### 1. 核心引擎 (General Engine) - 🌟 所有專案必讀
- `01-general-engine.md`: 定義跨領域通用的 AI 協作協議（如 Checklist 回報機制）、Git 禮儀與 TypeScript 等基礎語言品質門檻。

### 2. 前端領域 (Frontend Domain) - 🖥️ 前端專案必讀
- `frontend/02-frontend-standard.md`: 定義前端架構邊界 (UI/Service/API)、Data Flow (Mapper 轉換機制)、Headless UI 哲學與 i18n 策略。
- **特定框架策略 (選讀其中一項):**
  - `frontend/strategies/nextjs-app-router.md`: 若專案為 Next.js App Router，需讀取此檔（包含 RSC 規則與 shadcn/ui 限制）。
  - *(未來擴充: angular-enterprise.md, nuxt-composition.md 等)*

### 3. 未來擴充領域 (Future Domains)
- `backend/`: 預留給 Node.js, Golang, C# 等後端標準。
- `hardware/`: 預留給 C++, MCU 韌體等硬體標準。

---

## 🚀 步驟一：如何在專案中引入 (Integration)

強烈建議將此 Repo 作為 Git Submodule 掛載到目標專案的 `docs/skills/` 目錄下，以確保規則的統一與同步更新。

在你的目標專案根目錄執行：
```bash
git submodule add [https://github.com/jack755051/charlie-ai-protocols.git](https://github.com/jack755051/charlie-ai-protocols.git) docs/skills
```

---

## 🤖 步驟二：自動初始化 AI 大腦 (Auto-Initialization)

本 Repo 內建組裝腳本，可自動將規則合併為 AI 編輯器（如 Cursor）支援的 `.cursorrules`。

在專案根目錄執行以下指令：
```bash
# 針對 Next.js 專案：
bash docs/skills/init-ai.sh nextjs

# (未來擴充) 針對 C++ 硬體專案：
# bash docs/skills/init-ai.sh cpp

---