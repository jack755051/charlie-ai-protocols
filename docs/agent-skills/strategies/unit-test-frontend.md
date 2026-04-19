# Strategy: Frontend Unit Testing (v1.0)

> 本文件定義前端開發者 (04) 撰寫單元測試的標準。單元測試屬於白箱測試，由實作者自行負責，與 QA (07) 的整合/E2E/壓測互不重疊。

## 1. 職責邊界與測試金字塔定位 (Scope)

> **⚠️ 硬性規定：單元測試由 Frontend Agent (04) 產出，嚴禁推卸給 QA Agent (07)。**

- **你的範圍**：Mapper、Service/Facade 邏輯、UI 組件的渲染狀態與事件綁定。
- **不在你的範圍**：跨頁業務流驗證 (E2E)、API 契約驗證 (Integration)、效能壓測 (k6)。這些由 QA (07) 負責。
- **產出要求**：每個邏輯檔案必須伴隨對應的測試檔（如 `auth.mapper.ts` → `auth.mapper.spec.ts`）。

## 2. Mock 策略與隔離邊界 (Mock Boundary)

> **⚠️ 硬性規定：單元測試絕對禁止發出真實 HTTP 請求或連線後端服務。**

- **HTTP Client**：所有 API 呼叫必須 Mock。Angular 使用 `HttpClientTestingModule` / `provideHttpClientTesting()`；React/Vue 使用 `msw` 或手動 Mock fetch/axios。
- **Router**：禁止在單元測試中掛載真實 Router。Angular 使用 `RouterTestingModule` 或 Mock `ActivatedRoute`；Next.js Mock `next/navigation`；Nuxt Mock `useRouter()`。
- **Store / 狀態管理**：禁止掛載真實全域 Store。必須注入 Mock Provider 或使用 Testing Store（如 NgRx `provideMockStore()`、Pinia `createTestingPinia()`）。
- **第三方服務**：外部 SDK（地圖、金流、分析）一律 Mock，嚴禁在單元測試中初始化真實 SDK 實例。

## 3. 測試分層規範 (Testing Layers)

### 3.1 Mapper / 純函式層
- **驗證重點**：DTO → Domain Model 的轉換邏輯、邊界值（null、空陣列、非預期型別）。
- **禁止項**：此層嚴禁出現任何框架依賴（無 DI、無 Component、無 DOM）。

### 3.2 Service / Facade 層
- **驗證重點**：業務邏輯流程（呼叫順序、條件分支、錯誤處理）。
- **隔離方式**：Mock 底層 HTTP Client 與 Store，僅驗證 Service 的輸入輸出與副作用。

### 3.3 UI 組件層
- **驗證重點**：組件渲染是否正確反映輸入狀態、使用者事件是否觸發預期回呼。
- **禁止項**：嚴禁測試框架內部實作細節（如 Angular 的 Change Detection 次數、React 的 re-render 次數）。
- **斷言優先級**：優先使用語意化查詢（Role > TestId > Text），與 Playwright E2E 的 Locator Priority 保持一致。

## 4. 框架特化規範 (Framework-Specific Rules)

#### IF [Angular]：
- **測試工具**：使用 Jest 或 Karma + Jasmine（依專案配置）。
- **Standalone 組件測試**：使用 `TestBed.configureTestingModule({ imports: [ComponentUnderTest] })`，嚴禁在測試中建立 `NgModule`。
- **Signal 測試**：驗證 `input()` / `computed()` 的值變化，使用 `fixture.componentRef.setInput()` 設定輸入。
- **訂閱洩漏檢查**：測試中建立的 Observable 訂閱，必須在 `afterEach` 中確認已退訂。

#### IF [Next.js]：
- **測試工具**：使用 Vitest + React Testing Library。
- **Server Component**：Server Component 的資料邏輯應抽為純函式獨立測試，嚴禁在單元測試中模擬完整 RSC 渲染。
- **Client Component**：使用 `render()` + `screen` 查詢 DOM，驗證狀態與事件。

#### IF [Nuxt.js]：
- **測試工具**：使用 Vitest + @vue/test-utils。
- **Composable 測試**：自訂 `useXxx()` 必須獨立測試，Mock `useFetch` / `useAsyncData` 的回傳值。
- **組件測試**：使用 `mount()` / `shallowMount()`，透過 `props` 注入資料，驗證渲染結果與 `emits`。

## 5. 專案慣例與遺留守護 (Legacy & Conventions)

- **歷史拼寫守護**：測試檔案路徑必須沿用指定的歷史拼寫（如 `src/api/resquest/`），嚴禁在測試中「修正」既有目錄名稱。
- **命名慣例**：測試檔命名必須與原始碼一致，後綴為 `.spec.ts` 或 `.test.ts`（依專案統一慣例）。
