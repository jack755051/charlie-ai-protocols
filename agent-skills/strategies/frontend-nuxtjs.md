# Nuxt Composition Strategy (v1.0)

> 本文件定義針對 Nuxt 3/4 + Vue Composition API 的專屬實作細節。AI 在執行本專案任務時，必須優先採用此處定義的 SSR 資料流、路由機制與生態系工具。

## 1. 渲染策略 (Rendering Paradigm)

> **⚠️ 硬性規定：嚴禁妥協的 Nuxt SSR 與 Composition API 標準。**

- **強制 SSR/Universal 優先**：頁面資料載入預設必須使用 `useAsyncData` 或 `useFetch` 在 Server 端完成首屏準備，嚴禁將所有 fetching 延後到純 Client `onMounted()`。
- **嚴格 Client-only 邊界**：僅當確實依賴瀏覽器 API（`window`、`localStorage`）或純前端互動時，才使用 `<ClientOnly>` 或 `import.meta.client` 包住邏輯。
- **強制混合渲染拆分 (Server Wrapper Pattern)**：若畫面區塊同時需要 SSR Data Fetching 與 Client Interactivity，**絕對必須**拆解：
  - **Server/Page Wrapper**：負責 `await useAsyncData()` 並整理資料。
  - **Client Child**：以 props 接收資料，專注處理互動或表單。
- **Composition API 寫法**：預設使用 `<script setup lang="ts">`。元件衍生狀態強制使用 `computed()`，使用 `watch()` 必須明確控制來源與清理行為。

## 2. 路由機制與目錄約定 (Nuxt Routing Conventions)

- **目錄職責**：`pages/` 僅負責路由入口，實際業務區塊下放到 `components/sections`。
- **保留檔名鎖定**：框架保留目錄（`app.vue`, `pages/`, `layouts/`, `middleware/` 等）不可更名。
- **路由目錄語法**：保留 Nuxt 特徵：Route Groups `(folder-name)`、Dynamic Routes `[id].vue`。
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：邏輯中（如 `<NuxtLink to="...">`、`MapsTo()`），嚴禁直接寫死魔法字串路徑。
  - **統一引用**：導覽邏輯必須從專案靜態路由設定檔（如 `constants/routes.ts`）引入。
- **Page 檔極簡化 (Thin Page)**：`pages/**/*.vue` 應盡量輕薄，只允許做 layout 組裝與 route-level data fetching，嚴禁塞入細部互動流程。

## 3. 狀態管理策略 (State Management)

> **⚠️ 硬性規定：必須嚴格依據 PM (01) 交接單中指定的狀態管理策略執行。**

- **情境 A：中小型專案 (交接單指定 Composables)**
  - 嚴禁引入 Pinia。
  - 依賴 Nuxt 的 `useState` (具備 SSR 安全特性) 或單純的 Vue Composables 管理狀態。

- **情境 B：大型複雜專案 (交接單指定 Pinia)**
  - **Pinia 僅用於前端狀態**：遠端 API 資料優先交由 `useAsyncData`/`useFetch`。Pinia 僅用於跨頁共享之前端狀態（如登入 session、複雜篩選）。
  - **SSR 安全防污染**：Store 必須使用 `defineStore()` 建立。**禁止**在 store 檔案 module scope 宣告可變 singleton 物件。讀取 `localStorage` 必須放在 `import.meta.client` guard 之後。
  - **Store 拆分**：按 Feature 拆分 Store，Component 端解構 state 必須使用 `storeToRefs()`。

## 4. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎元件 (shadcn-vue)**：本專案優先綁定 `shadcn-vue`。
  - AI 設計新區塊時，必須優先從 `components/ui/` import。
  - **禁止手刻**：若缺少元件，AI 不可自行手刻或寫死 CSS，必須提示開發者執行 `npx shadcn-vue@latest add [元件名稱]`。
- **圖示庫 (Icons)**：僅能使用 `lucide-vue-next`，禁止混用 `lucide-react`。
- **動畫庫**：複雜互動統一使用 `@vueuse/motion`；簡單過場使用 Vue `<Transition>`，禁止手動操作 DOM style。

## 5. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫 API 必須透過 `useRuntimeConfig()`。Server-only 放在 private config，公開給 Client 的必須放在 `runtimeConfig.public`。**禁止**直接讀取 `process.env`。
- **Nuxt 專屬 Router API**：操作路由必須使用 `MapsTo()`、`useRoute()`、`useRouter()` 與 `<NuxtLink>`。**禁止**使用 `window.location`。
- **資料存取分層**：API 呼叫應優先透過 `services/` 封裝，禁止在 `pages/` 內直接處理 raw DTO。

## 6. 專案歷史遺留與架構約定 (Legacy & Project Conventions)

> **注意：尊重既有程式碼是不可侵犯之底線。**
- **沿用既有結構與拼寫**：接手既有專案時，若發現目錄存在歷史遺留錯誤（例如 `src/api/resquest` 拼寫錯誤），**絕對必須沿用現況**。嚴禁 AI 擅自「修正」拼寫並建立新目錄，導致雙軌並行。