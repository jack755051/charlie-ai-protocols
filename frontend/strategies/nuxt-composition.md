# Nuxt Composition Strategy (v1.0)

> 本文件定義針對 Nuxt 3/4 + Vue Composition API 的專屬實作細節。AI 在執行本專案任務時，必須優先採用此處定義的 SSR 資料流、路由機制、Pinia 狀態管理與 Nuxt 生態系工具。

## 1. 渲染策略 (Rendering Paradigm)

- **SSR/Universal 優先**：頁面資料載入預設優先走 Nuxt 的 SSR-friendly 模式，使用 `useAsyncData`、`useFetch` 或 server routes 在伺服器端完成首屏資料準備，避免把所有 fetching 都延後到純 Client `onMounted()`。
- **Client-only 邊界**：只有當元件確實依賴瀏覽器 API（如 `window`、`localStorage`）、第三方 DOM 套件或純前端互動初始化時，才使用 `<ClientOnly>`、`import.meta.client` guard 或 `onMounted()` 包住對應邏輯。
- **混合渲染拆分 (Server Wrapper Pattern)**：若某個畫面區塊同時需要 SSR Data Fetching 與 Client Interactivity，必須強制拆解：
  - **Server/Page Wrapper**：在 page 或 section wrapper 內負責 `await useAsyncData()` / `await useFetch()` 並整理資料。
  - **Client Child**：以純 props 接收資料，專注處理互動、表單、動畫或 Pinia 狀態綁定，避免在同一層混雜瀏覽器 API 與 server fetch。
- **Composition API 寫法**：Vue 元件預設使用 `<script setup lang="ts">` 與 Composition API，元件內衍生狀態優先用 `computed()`，一次性副作用用 `watch()` / `watchEffect()` 時必須明確控制來源與清理行為。

## 2. 路由機制與目錄約定 (Nuxt Routing Conventions)

- **目錄職責**：`pages/` 僅負責路由入口與頁面組裝，`layouts/` 負責外層版型，`middleware/` 負責導頁守衛，`error.vue` 負責全域錯誤頁。實際業務區塊應下放到 `components/sections`、feature components 或 composables/services。
- **保留檔名與目錄鎖定**：Nuxt 框架保留入口檔與目錄不可隨意更名，包含：`app.vue`、`error.vue`、`pages/`、`layouts/`、`middleware/`、`plugins/`、`composables/`、`server/`。
- **路由目錄語法**：一般資料夾與頁面檔名使用 `kebab-case`。遇到 Nuxt 檔案路由語法時，必須保留其符號特徵：
  - Route Groups: `(folder-name)`
  - Dynamic Routes: `[id].vue`
  - Catch-all Routes: `[...slug].vue` 或 `[[...slug]].vue`
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：UI 元件或邏輯中（如 `<NuxtLink to="...">`、`navigateTo()`、`router.push()`），嚴禁直接寫死魔法字串路徑。
  - **統一引用**：導覽邏輯必須從專案的靜態路由設定檔（例如 `constants/routes.ts` 或 `src/constants/routes.ts`）引入路徑變數（例如 `ROUTES.EXPLORE.TRIPS`）。
  - **i18n 與 Breadcrumb 綁定**：多語系導覽列、麵包屑與 route meta 應參照靜態路由表中的 `i18nKey`、`parent` 或對應 metadata 產生，避免各頁面自行硬寫文案與層級。
- **Page 檔極簡化 (Thin Page)**：`pages/**/*.vue` 檔案應盡量保持輕薄，只允許做 layout/section 組裝、`definePageMeta()`、route-level data fetching 與必要的 SEO 設定，嚴禁塞入冗長的 presentational markup 或細部互動流程。

## 3. 狀態管理策略 (State Management: Pinia)

本專案 Nuxt 實作採用 **Pinia** 作為前端全域狀態管理工具。

- **資料抓取 vs UI 狀態**：
  - 來自遠端 API 且適合首屏渲染的資料流，優先交由 `useAsyncData`、`useFetch`、server routes 或 service/composable 封裝處理。
  - **Pinia 僅用於管理跨頁或跨元件共享的前端狀態**（如：登入者 UI session、側邊欄開關、多步表單暫存、複雜篩選條件），避免把所有 server cache 都塞進 store。
- **SSR 安全寫法 (防污染)**：
  - Store 必須使用 `defineStore()` 建立，狀態初始值需寫在 `state: () => ({ ... })` 或 setup store 內部，**禁止**在 store 檔案 module scope 宣告可變 singleton 物件/陣列後直接共用，避免跨 request 污染。
  - 若 store 需要讀取 `localStorage`、`window` 或其他 browser-only API，必須放在 client-only plugin、`onMounted()`、action 的 `import.meta.client` guard 之後執行，禁止在 SSR 初始化階段直接存取瀏覽器物件。
- **Store 拆分**：按 Feature 拆分 Store（例如 `useAuthStore`、`useFilterStore`），禁止建立單一巨型 Store；Component 端解構 state/getters 時優先使用 `storeToRefs()` 保留 reactivity，actions 則直接由 store 實例呼叫。

## 4. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎元件 (shadcn-vue)**：本專案 Nuxt 版本優先綁定 `shadcn-vue`。
  - AI 在設計新區塊時，若需要基礎元件，必須優先從 `components/ui/` 或專案既有 UI primitives import。
  - 若專案目前缺少該元件，**AI 不可自行手刻一套重複 primitive 或寫死 CSS**，必須提示開發者執行 `npx shadcn-vue@latest add [元件名稱]`。
- **圖示庫 (Icons)**：必須且僅能使用 `lucide-vue-next`，禁止混用 `lucide-react` 或其他未授權 Icon 套件。
- **動畫庫**：複雜互動動畫統一使用 `@vueuse/motion`；簡單顯示/隱藏過場可使用 Vue `<Transition>` / `<TransitionGroup>`，禁止直接手動操作 DOM style 取代資料驅動畫面。

## 5. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫內部或外部 API 時，必須透過 `useRuntimeConfig()` 依執行端切換設定。Server-only endpoint/secret 放在 private runtime config（例如 `runtimeConfig.internalApiUrl`），可公開給 Client 的 base URL 才能放在 `runtimeConfig.public.apiBaseUrl`。**禁止**在元件或 composable 內直接散落讀取 `process.env`。
- **Nuxt 專屬 Router API**：若需操作路由或取得目前路徑/參數，必須使用 `navigateTo()`、`useRoute()`、`useRouter()` 與 `<NuxtLink>`。**禁止**直接用 `window.location` 或手寫 History API 取代 Nuxt Router。
- **資料存取分層**：頁面或 composable 呼叫 API 時，應優先透過 `services/` 與 `api/` 層封裝 `$fetch` / `useFetch` 與 DTO -> Domain Mapper，禁止在 `pages/**/*.vue` 內直接拼 API URL 或處理 raw DTO 欄位改名。

## 6. 專案特有歷史遺留約定 (Project Specific Legacy)

> **注意：此為本專案不可侵犯之底線。**
- **DTO 目錄拼寫**：目前 Trip Master 專案 Request DTO 的實際目錄為 `src/api/resquest`（帶有拼字錯誤）。在 import 或新增 DTO 檔案時，**必須沿用現況**。若要修正目錄拼字，必須經過人類開發者授權並開獨立 PR 執行，**絕對禁止** AI 擅自新增一個正確拼寫的 `request/` 目錄造成雙軌並行。
