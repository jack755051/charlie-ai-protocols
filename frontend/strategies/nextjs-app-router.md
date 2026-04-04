# Next.js App Router Strategy (v1.0)

> 本文件定義針對 Next.js (App Router) 的專屬實作細節。AI 在執行本專案任務時，必須優先採用此處定義的渲染策略、路由慣例與生態系工具。

## 1. 渲染策略 (Rendering Paradigm)

- **Server Component 優先 (RSC First)**：所有 React 元件預設為 Server Component。
- **Client Component 邊界**：只有當元件需要使用 React Hooks (`useState`, `useEffect`)、瀏覽器 API (如 `window`)、DOM 事件 (`onClick`) 或 Context 時，才在檔案最頂端加上 `"use client"`。
- **混合渲染拆分 (Server Wrapper Pattern)**：若某個畫面區塊同時需要 Server Data Fetching 與 Client Interactivity，必須強制拆解：
  - **Server Wrapper**: 負責抓取資料 (例如 `trending-section.tsx`)。
  - **Client Child**: 標記 `"use client"` 並接收資料作為 props 處理互動 (例如 `trending-section-client.tsx`)。

## 2. 路由與檔案約定 (App Router Conventions)

- **目錄職責**：`src/app` 僅負責路由入口 (Route Entry)、版面組裝 (Layout) 與錯誤邊界。
- **保留檔名鎖定**：Next.js 框架保留檔名**絕對不可更改**，包含：`page.tsx`、`layout.tsx`、`loading.tsx`、`error.tsx`、`not-found.tsx`。
- **路由目錄命名**：一般資料夾使用 `kebab-case`。但遇到 Next.js 路由語法時，必須保留其符號特徵：
  - Route Groups: `(folder-name)`
  - Dynamic Routes: `[id]` 或 `[...slug]`
- **Page 檔極簡化**：`page.tsx` 檔案應盡量保持輕薄 (Thin Page)。只允許做 Section/Layout 的組裝與必要的 Route-level Data Fetching，**嚴禁**在 `page.tsx` 內塞入冗長的 JSX 或細部互動邏輯。

## 3. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫內部或外部 API 時，必須根據執行環境切換 URL。Server 端使用 `INTERNAL_API_URL`，Client 端必須加上前綴使用 `NEXT_PUBLIC_API_BASE_URL`。
- **Next 專屬 Hooks**：若需操作路由或取得路徑，必須使用 `next/navigation` 提供的 `useRouter`、`usePathname` 或 `useSearchParams`，禁止使用舊版 `next/router`。

## 4. 專案特有歷史遺留約定 (Project Specific Legacy)

> **注意：此為本專案不可侵犯之底線。**
- **DTO 目錄拼寫**：目前專案 Request DTO 的實際目錄為 `src/api/resquest`（帶有拼字錯誤）。在 import 或新增 DTO 檔案時，**必須沿用現況**。若要修正目錄拼字，必須經過人類開發者授權並開獨立 PR 執行，**絕對禁止** AI 擅自新增一個正確拼寫的 `request/` 目錄造成雙軌並行。

## 5. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎元件 (shadcn/ui)**：本專案嚴格綁定 `shadcn/ui`。
  - AI 在設計新區塊時，若需要基礎元件，必須優先從 `src/components/ui/` 中 import。
  - 若專案目前缺少該元件，**AI 不可自行手刻或寫死 CSS**，必須提示開發者執行 `npx shadcn-ui@latest add [元件名稱]`。
- **圖示庫 (Icons)**：必須且僅能使用 `lucide-react`，禁止引入 `lucide-vue-next` 或其他第三方 Icon 庫。
- **動畫庫**：UI 複雜動畫統一使用 `framer-motion` 處理。