# Next.js App Router Strategy (v1.0)

> 本文件定義針對 Next.js (App Router) 的專屬實作細節。AI 在執行本專案任務時，必須優先採用此處定義的渲染策略、路由機制與生態系工具。

## 1. 渲染策略 (Rendering Paradigm)

- **Server Component 優先 (RSC First)**：所有 React 元件預設為 Server Component。
- **Client Component 邊界**：只有當元件需要使用 React Hooks (`useState`, `useEffect`)、瀏覽器 API (如 `window`)、DOM 事件 (`onClick`) 或 Context 時，才在檔案最頂端加上 `"use client"`。
- **混合渲染拆分 (Server Wrapper Pattern)**：若某個畫面區塊同時需要 Server Data Fetching 與 Client Interactivity，必須強制拆解：
  - **Server Wrapper**: 負責在 Server 端抓取資料 (例如 `trending-section.tsx`)。
  - **Client Child**: 標記 `"use client"` 並接收資料作為 props 處理互動 (例如 `trending-section-client.tsx`)。

## 2. 路由機制與目錄約定 (App Router Conventions)

- **目錄職責**：`src/app` 僅負責路由入口 (Route Entry)、版面組裝 (Layout) 與錯誤邊界。
- **保留檔名鎖定**：Next.js 框架保留檔名絕對不可更改，包含：`page.tsx`、`layout.tsx`、`loading.tsx`、`error.tsx`、`not-found.tsx`。
- **路由目錄語法**：一般資料夾使用 `kebab-case`。但遇到 Next.js 路由語法時，必須保留其符號特徵：
  - Route Groups: `(folder-name)`
  - Dynamic Routes: `[id]` 或 `[...slug]`
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：UI 元件或邏輯中（如 `<Link href="...">` 或 `router.push()`），嚴禁直接寫死魔法字串路徑（Magic Strings）。
  - **統一引用**：導覽邏輯必須從專案的靜態路由設定檔（如 `src/constants/routes.ts`）中引入路徑變數（例如 `ROUTES.EXPLORE.TRIPS`）。
  - **i18n 與 Breadcrumb 綁定**：在處理多語系導覽列或麵包屑時，必須參照靜態路由表中定義的 `i18nKey` 或 `parent` 屬性來動態渲染，確保全站路由具備高度可維護性。
- **Page 檔極簡化 (Thin Page)**：`page.tsx` 檔案應盡量保持輕薄。只允許做 Section/Layout 的組裝與必要的 Route-level Data Fetching，嚴禁在 `page.tsx` 內塞入冗長的 JSX 或細部互動邏輯。

## 3. 狀態管理策略 (State Management: Zustand)

本專案摒棄重型的 Redux，採用 **Zustand** 作為前端全域狀態管理工具。

- **資料抓取 vs UI 狀態**：
  - 來自遠端 API 的資料流，交由 Server Components 處理。
  - **Zustand 僅用於管理純 Client 端的跨元件 UI 狀態**（如：多步表單暫存、側邊欄開關、複雜的篩選條件）。
- **SSR 安全寫法 (防污染)**：
  - 在 Next.js App Router 中，為避免 Zustand 狀態在 Server 端的不同 Request 間互相污染，**禁止**直接 export 一個全域的 `create()` store。
  - 必須採用 **Zustand + React Context** 的模式。AI 在建立新的全域狀態時，必須同時提供 `StoreProvider` 來包裹需要該狀態的 Client Component 範圍。
- **Store 拆分**：按 Feature 拆分 Store（例如 `useAuthStore`、`useFilterStore`），禁止將所有無關狀態塞進同一個巨型 Store。

## 4. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎元件 (shadcn/ui)**：本專案嚴格綁定 `shadcn/ui`。
  - AI 在設計新區塊時，若需要基礎元件，必須優先從 `src/components/ui/` 中 import。
  - 若專案目前缺少該元件，**AI 不可自行手刻或寫死 CSS**，必須提示開發者執行 `npx shadcn-ui@latest add [元件名稱]`。
- **圖示庫 (Icons)**：必須且僅能使用 `lucide-react`，禁止引入 `lucide-vue-next` 或其他第三方 Icon 庫。
- **動畫庫**：UI 複雜動畫統一使用 `framer-motion` 處理。

## 5. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫內部或外部 API 時，必須根據執行環境切換 URL。Server 端使用 `INTERNAL_API_URL`，Client 端必須加上前綴使用 `NEXT_PUBLIC_API_BASE_URL`。
- **Next 專屬 Hooks**：若需操作路由或取得路徑，必須使用 `next/navigation` 提供的 `useRouter`、`usePathname` 或 `useSearchParams`，**絕對禁止**使用舊版的 `next/router`。

## 6. 專案特有歷史遺留約定 (Project Specific Legacy)

> **注意：此為本專案不可侵犯之底線。**
- **DTO 目錄拼寫**：目前 Trip Master 專案 Request DTO 的實際目錄為 `src/api/resquest`（帶有拼字錯誤）。在 import 或新增 DTO 檔案時，**必須沿用現況**。若要修正目錄拼字，必須經過人類開發者授權並開獨立 PR 執行，**絕對禁止** AI 擅自新增一個正確拼寫的 `request/` 目錄造成雙軌並行。