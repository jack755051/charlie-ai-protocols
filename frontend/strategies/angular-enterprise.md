# Angular Enterprise Strategy (v1.0)

> 本文件定義針對 Angular 的專屬實作細節與生態系規範。AI 在執行本專案任務時，必須優先採用此處定義的依賴注入、非同步處理與元件策略。

## 1. 元件與渲染策略 (Component Paradigm)

- **Standalone 優先**：所有新建的 Component、Directive 與 Pipe 必須標記為 `standalone: true`，禁止依賴傳統的 `NgModule` 來宣告。
- **效能優化 (OnPush)**：所有 UI Presentation Component 必須設定 `changeDetection: ChangeDetectionStrategy.OnPush`。
- **Signals 與響應式 (Modern Angular)**：若專案版本允許 (v16+)：
  - 優先使用 `input()`、`output()` 與 `computed()` 等 Signal API 來取代傳統的 `@Input()` 與 `@Output()`。
  - 元件內的純同步狀態衍生，優先使用 Signal 而非 RxJS `BehaviorSubject`。

## 2. RxJS 與非同步處理規範 (Async & RxJS Strictness)

> **注意：此為 Angular 專案防範 Bug 的最高指導原則。**

- **禁止訂閱地獄 (No Nested Subscribes)**：絕對禁止在 `subscribe()` 內部再次呼叫另一個 `subscribe()`。必須使用 Higher-Order Mapping Operators (`switchMap`, `mergeMap`, `concatMap`, `exhaustMap`) 來串接非同步流程。
- **自動取消訂閱 (Memory Leak Prevention)**：
  - **首選**：在 Template 中使用 `| async` pipe，讓 Angular 自動管理訂閱生命週期。
  - **次選**：在 TypeScript 中訂閱時，必須使用 `takeUntilDestroyed()` (v16+) 確保元件銷毀時自動退訂。
- **Service 的回傳值**：HTTP Service 的方法必須回傳 `Observable<T>`，禁止在 Service 內部直接 `subscribe()` 並將結果賦值給變數。資料流的啟動由 Component 決定。

## 3. 狀態管理策略 (State Management: NgRx)

若專案引入了 NgRx（或 NGXS），必須嚴守「Smart / Dumb Component」架構：

- **單向資料流**：Component 只能做兩件事：
  1. 透過 `Store.select()` 或 `Store.selectSignal()` 讀取狀態。
  2. 透過 `Store.dispatch()` 發送 Action。
- **嚴禁副作用**：Reducer 必須是純函數（Pure Function），任何牽涉到 API 呼叫、路由跳轉的副作用邏輯，**只能**寫在 Effects 中。
- **Facade Pattern (外觀模式)**：複雜的 Feature 模組應建立 `xxx.facade.ts` 封裝 Store 的 select 與 dispatch，Component 只與 Facade 互動，不直接依賴 Store。

## 4. 路由機制與架構約定 (Routing & Architecture)

- **目錄職責**：`app.routes.ts` 與 Route Shell Component 只負責路由入口、版面組裝、Guards/Resolvers 掛載與錯誤分流。實際業務區塊與細部 UI 應下放到 feature 目錄或 `components/sections`，禁止把完整頁面細節全部塞進 route entry component。
- **延遲載入 (Lazy Loading)**：路由必須採用 Lazy Loading。使用 `loadComponent` 載入單一元件，或使用 `loadChildren` 載入子路由群組，嚴禁在全域路由直接 import 元件實體。
- **路由路徑語法**：Route config 內的一般 path 使用 `kebab-case`；動態參數使用 `:id` 形式，fallback route 使用 `**`，禁止自行用魔法字串拼接未註冊路由。
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：Template 的 `[routerLink]`、TypeScript 的 `router.navigate()` / `router.navigateByUrl()`，嚴禁直接散落 magic string path。
  - **統一引用**：導覽邏輯必須從專案路由常數檔（例如 `src/constants/routes.ts` 或 `src/app/constants/routes.ts`）引用路徑定義。
  - **i18n 與 Breadcrumb 綁定**：多語系導覽與麵包屑應優先讀取路由定義或 Route `data` 中的 `i18nKey`、`parent`、`breadcrumb` metadata，避免每個頁面自行硬寫顯示名稱。
- **Route Shell 極簡化 (Thin Page)**：Route entry component 應盡量保持輕薄，只處理 section/layout 組裝、route param/query param 讀取與必要的 facade/service 呼叫，禁止承載大量 presentational markup 或深層互動流程。
- **HTTP 攔截器 (Interceptors)**：所有的 API Token 注入、全域錯誤攔截 (如 401 導向登入頁) 必須寫在 HTTP Interceptor 中，禁止在各別 Service 中重複實作處理邏輯。
- **檔案命名規範**：嚴格遵守 Angular CLI 慣例：
  - 元件：`feature-name.component.ts` / `.html` / `.scss`
  - 服務：`feature-name.service.ts`
  - 狀態：`feature-name.actions.ts`, `feature-name.reducer.ts`

## 5. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎庫 (Spartan/Material)**：*(註：請根據你實際的 Angular 專案選擇，此處以 Spartan 為例)* - 本專案採用 `spartan/ui` (Angular 版的 shadcn 實作) 搭配 Tailwind CSS。
  - AI 在新增 UI 時，需優先查閱 `@spartan-ng/ui-*` 套件。
- **圖示庫 (Icons)**：使用 `lucide-angular` 搭配 `@spartan-ng/ui-icon-brain` 處理圖示。
- **動畫庫**：複雜 UI 動畫優先使用 `@angular/animations`，簡單 enter/leave transition 可搭配 Tailwind class，但禁止在元件內直接用 `document.querySelector()` 或手動操作 DOM style 來驅動畫面狀態。
- **樣式隔離**：預設使用 `ViewEncapsulation.Emulated`，禁止使用 `::ng-deep` 穿透修改第三方套件樣式（除非透過全域 CSS 變數覆寫）。

## 6. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：呼叫內部或外部 API 時，禁止在 Service 內硬編碼 base URL。Client Bundle 應統一讀取 `src/environments/environment*.ts` 或專案封裝的 runtime config；若專案啟用 Angular SSR，Server-only endpoint/secret 必須留在 server runtime，禁止放進會被前端打包的 `environment` 檔。
- **Angular 專屬 Router API**：若需導頁或讀取目前路由狀態，必須使用 `Router`、`ActivatedRoute`、`RouterLink`、`paramMap`、`queryParamMap`，必要時搭配 `toSignal()` 轉成 Signal。**禁止**直接操作 `window.location` 取代 Angular Router，也禁止手刻 query string parser。

## 7. 專案特有歷史遺留約定 (Project Specific Legacy)

> **注意：此為本專案不可侵犯之底線。**
- **DTO 目錄拼寫**：目前 Trip Master 專案 Request DTO 的實際目錄為 `src/api/resquest`（帶有拼字錯誤）。在 import 或新增 DTO 檔案時，**必須沿用現況**。若要修正目錄拼字，必須經過人類開發者授權並開獨立 PR 執行，**絕對禁止** AI 擅自新增一個正確拼寫的 `request/` 目錄造成雙軌並行。
