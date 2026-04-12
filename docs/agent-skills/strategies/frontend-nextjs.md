# Next.js App Router Strategy (v1.0)

> 本文件定義針對 Next.js (App Router) 的專屬實作細節。AI 在執行本專案任務時，必須優先採用此處定義的渲染策略、路由機制與生態系工具。

## 1. 渲染策略 (Rendering Paradigm)

> **⚠️ 硬性規定：嚴禁妥協的 App Router 渲染標準。**

- **強制 Server Component 優先 (RSC First)**：所有 React 元件預設必須為 Server Component。
- **嚴格 Client Component 邊界**：只有當元件確實需要使用 React Hooks (`useState`, `useEffect`)、瀏覽器 API (如 `window`)、DOM 事件 (`onClick`) 或 React Context 時，才允許在檔案最頂端宣告 `"use client"`。
- **強制混合渲染拆分 (Server Wrapper Pattern)**：若畫面區塊同時需要 Server Data Fetching 與 Client Interactivity，**絕對必須**拆解：
  - **Server Wrapper**: 負責在 Server 端抓取資料。
  - **Client Child**: 標記 `"use client"` 並接收資料作為 props 處理互動。嚴禁在 Client Component 內直接進行 Server Fetch。

## 2. 路由機制與目錄約定 (App Router Conventions)

- **目錄職責**：`src/app` 僅負責路由入口、版面組裝與錯誤邊界。
- **保留檔名鎖定**：框架保留檔名（`page.tsx`, `layout.tsx`, `loading.tsx`, `error.tsx`, `not-found.tsx`）絕對不可更改。
- **路由目錄語法**：遇到 Next.js 路由語法時，必須保留其符號特徵：Route Groups `(folder-name)`、Dynamic Routes `[id]`。
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：UI 元件或邏輯中（如 `<Link href="...">` 或 `router.push()`），嚴禁直接寫死魔法字串路徑。
  - **統一引用**：導覽邏輯必須從專案靜態路由設定檔（如 `src/constants/routes.ts`）中引入路徑變數。
- **Page 檔極簡化 (Thin Page)**：`page.tsx` 檔案應盡量保持輕薄。只允許做 Section/Layout 的組裝與 Route-level Data Fetching，嚴禁塞入冗長的 JSX 或細部互動邏輯。

## 3. 狀態管理策略 (State Management)

> **⚠️ 硬性規定：必須嚴格依據 PM (01) 交接單中指定的狀態管理策略執行。**

本專案摒棄重型的 Redux。

- **情境 A：中小型專案 (交接單指定 Context/Props)**
  - 嚴禁引入 Zustand 或 Redux。
  - 依賴 React Context 或單純的 Props Drilling 管理局部狀態。

- **情境 B：大型複雜專案 (交接單指定 Zustand)**
  - **Zustand 僅用於純 Client 端狀態**：來自遠端 API 的資料流交由 Server Components 處理。Zustand 僅用於跨元件 UI 狀態（如多步表單、側邊欄）。
  - **SSR 安全防污染**：為避免狀態在 Server 端跨 Request 污染，**禁止**直接 export 全域的 `create()` store。必須採用 **Zustand + React Context** 模式，提供 `StoreProvider` 包裹 Client 範圍。
  - **Store 拆分**：按 Feature 拆分 Store，禁止建立巨型 Store。

## 4. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎元件 (shadcn-ui)**：本專案嚴格綁定 `shadcn/ui`。
  - AI 設計新區塊時，必須優先從 `src/components/ui/` import。
  - **禁止手刻**：若缺少元件，AI 不可自行手刻或寫死 CSS，必須提示開發者執行 `npx shadcn-ui@latest add [元件名稱]`。
- **圖示庫 (Icons)**：僅能使用 `lucide-react`。
- **動畫庫**：統一使用 `framer-motion`。

## 5. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫 API 必須切換環境。Server 端使用 `INTERNAL_API_URL`，Client 端必須加上前綴使用 `NEXT_PUBLIC_API_BASE_URL`。
- **Next 專屬 Hooks**：操作路由必須使用 `next/navigation` 的 `useRouter`、`usePathname` 或 `useSearchParams`，**絕對禁止**使用舊版 `next/router`。

## 6. 專案歷史遺留與架構約定 (Legacy & Project Conventions)

> **注意：尊重既有程式碼是不可侵犯之底線。**
- **沿用既有結構與拼寫**：接手既有專案時，若發現目錄存在歷史遺留錯誤（例如 `src/api/resquest` 拼寫錯誤），**絕對必須沿用現況**。嚴禁 AI 擅自「修正」拼寫並建立新目錄，導致雙軌並行。