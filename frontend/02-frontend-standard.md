# Frontend Domain Standard (v1.0)

> 本文件定義前端領域的通用架構、資料流向與 UI 開發規範。無論底層使用何種前端框架，皆須遵守此邊界劃分與設計模式。

## 1. 目錄分層與責任邊界 (Architecture Layers)

前端架構應嚴格區分「業務邏輯」、「資料存取」與「UI 呈現」，禁止邏輯互相污染：

- **UI 基礎層 (`components/ui`)**：低階 UI primitives（如按鈕、輸入框），僅負責呈現與基本互動，**嚴禁**塞入業務邏輯或呼叫 API。
- **跨頁共用層 (`components/common`)**：具有特定語意的共用元件（如 `Logo`、`TripCard`、切換語系元件）。
- **業務區塊層 (`components/sections`)**：頁面級別的主區塊。大型功能應拆解至此層，再交由外層頁面組裝。內部子元件若無對外共用需求，應留在 section 資料夾內部。
- **服務層 (`services`)**：負責資料存取、外部 I/O 協調。Service 回傳給 UI 的必須是經過清洗的 Domain Model，**絕對不可以**是原始的 DTO。
- **API 與映射層 (`api`)**：集中管理 HTTP Client、URL 設定、Request/Response DTO 型別定義，以及最核心的 Mapper 轉換邏輯。

## 2. 遠端資料流機制 (The API-to-UI Flow)

新增或調整 API 介接時，必須嚴格遵守以下單向資料流順序：

1. **Contract First**: 定義 API Endpoint 與 Request/Response DTO 型別。
2. **Mapper 轉換**: 建立 Mapping 邏輯，將後端格式 (DTO) 轉換為前端介面使用的型別 (Domain Model)。**UI 層絕對不要直接吃 Raw DTO 或在元件內處理欄位改名。**
3. **Service 封裝**: 實作 Service 方法。Service 可依據環境變數決定要走真實 API 或 Mock Data，但回傳前**必須**經過 Mapper 轉換。
4. **UI 消費**: 由 Section / Hook / Composable / Facade 呼叫 Service 並取得最終資料，禁止在元件內重複拼接 URL 或解析原始 API 結構。

## 3. 路由與頁面殼層原則 (Routing & Page Shell)

- **集中式路由表**：禁止在 UI 元件、導覽邏輯或業務流程中散落硬編碼路徑字串。路由 path、對應名稱與階層關係應集中定義在路由常數表或 route metadata 中。
- **Thin Page / Thin Route Shell**：路由入口頁或 route shell 只負責 Layout/Section 組裝、route params/query 讀取、route-level data loading、SEO/meta 與錯誤邊界掛載；禁止把大量 presentational markup 或深層互動細節直接塞進 page entry。
- **i18n / Breadcrumb Metadata**：多語系導覽與麵包屑應優先依路由表或 route metadata 中的 `i18nKey`、`parent`、`breadcrumb` 等欄位產生，避免每個頁面自行硬寫文案與階層。
- **框架路由語法下放**：Dynamic Route、Catch-all、Route Group、Guard/Middleware 等語法細節，由各 framework strategy 文件定義；本文件只約束「集中管理」與「頁面殼層要薄」這兩個共通原則。

## 4. 樣式與 UI 元件庫哲學 (UI & Styling Philosophy)

- **Headless UI 優先**：禁止引入帶有強烈預設樣式且難以覆蓋的巨型組件庫（如 Ant Design, Material UI）。UI 基礎元件必須以原始碼形式存在於專案內部（如 `src/components/ui/`），確保擁有完全的自定義控制權。
- **Tailwind 驅動**：預設使用 Tailwind class，並依框架採用對應的 class merge / class binding 機制（如 `cn()`、`:class`、`[ngClass]`）。禁止使用 inline style，除非是動態計算的 CSS 變數或無法用 class 表達的屬性。
- **色彩約束 (Color Constraint)**：**絕對禁止**新增 UI 時直接散落硬編碼色（如 `text-[#333]`、`bg-blue-500`）。必須優先搜尋全域 CSS 變數或既有語意 token（例如 `bg-background`、`text-primary`）。若無合適 token，請先定義設計語意。
- **BEM-Tailwind 混合模式**：針對複雜的大型 Section，建議採用 BEM 概念組織 Tailwind 結構：
  - 最外層: `block--container`
  - 內容層: `block__content`
  - 子元素: `block__element`

## 5. 狀態管理與表單 (State & Forms)

- **狀態收斂**：全域狀態（如語系、使用者權限）交由 Provider / Store / Facade / Service 等框架對應機制管理。局部 UI 狀態請留在元件內，或抽離至 Hook / Composable / Facade / helper service。
- **可重用邏輯拆分原則**：`hooks` / `composables` / `facades` 等目錄只放「真正可重用」的邏輯。若只是單一元件內的輔助邏輯，請留在元件旁，不要為了符合特定行數門檻硬拆抽象層。
- **表單驅動**：複雜表單統一使用 Schema-based 驗證（如 Zod）搭配表單狀態庫。Schema 定義應與 Section 放在同一 feature 目錄下（高內聚）。表單錯誤 UI 需沿用專案既有模式，禁止各自發明錯誤提示 DOM。

## 6. 多語系文案規則 (i18n Strictness)

- **禁止硬編碼**：所有可見文案必須提取至語系字典檔（如 `src/config/i18n`），UI 元件只能透過框架對應的 i18n 取值層（Hook / Composable / Service / Pipe / Directive）取得文案。
- **同步補齊**：新增文案 key 時，必須同步補齊所有支援語系的字典檔，避免畫面出現 raw key。
- **全域切換**：語系切換必須透過統一的 Provider 或機制處理，不可在單一元件內自定義語系狀態。

## 7. 環境變數與 SSR / Client 邊界 (Environment & Runtime Boundary)

- **禁止硬編碼 API Base URL**：API base URL、mock 開關、第三方服務 endpoint 等環境差異，必須集中由 `api` / `services` 層讀取環境設定或 runtime config，禁止在元件或散落 utility 中直接硬寫。
- **Public / Private Env 分離**：可下發到 Client Bundle 的 public env 與只能留在 Server Runtime 的 secret/private env 必須明確分離。任何 token、內網 endpoint、server-only secret 都不得放進前端可見設定。
- **Browser API Client-only Guard**：`window`、`document`、`localStorage`、DOM SDK 初始化等瀏覽器限定 API，必須使用 framework strategy 規範的 client-only guard / lifecycle 包住，避免 SSR crash 或 hydration mismatch。

## 8. 檔案與命名慣例 (Naming Conventions)

- **UI 元件 (Components)**：檔案使用 `kebab-case`（如 `.tsx`, `.vue`），元件 function/類別標識符使用 `PascalCase`。
- **Hooks / Composables 命名**：若框架採用 Hook / Composable 慣例，檔案與函式皆使用 `useXxx`（例如 `useAuth.ts`），禁止綴以多餘的後綴（如 `useAuthHook`）。若特定框架另有官方慣例（如 Angular 的 `*.service.ts`、`*.facade.ts`），以對應 framework strategy 文件覆蓋本條命名規則。
- **型別與介面**：共用型別使用 `*.type.ts`，API 傳輸物件使用 `*.request.dto.ts` / `*.response.dto.ts`。
