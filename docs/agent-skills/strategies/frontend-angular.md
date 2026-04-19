# Angular Enterprise Strategy (v1.0)

> 本文件定義針對 Angular 的專屬實作細節與生態系規範。AI 在執行本專案任務時，必須優先採用此處定義的依賴注入、非同步處理與元件策略。

## 1. 元件與渲染策略 (Component Paradigm)

> **⚠️ 硬性規定：嚴禁妥協的現代化 Angular 標準。**

- **強制 Standalone**：所有新建的 Component、Directive 與 Pipe **絕對必須**標記為 `standalone: true`。嚴禁在專案中新增任何 `NgModule`（除專案根模組歷史遺留外）。
- **效能優化 (OnPush)**：所有 UI Presentation Component 必須設定 `changeDetection: ChangeDetectionStrategy.OnPush`。
- **強制 Signals 響應式 (Modern Angular)**：
  - **取代裝飾器**：必須使用 `input()`, `output()`, `model()` 與 `computed()` 等 Signal API，**嚴禁**使用傳統的 `@Input()` 與 `@Output()`。
  - **取代生命週期**：純同步的狀態衍生必須使用 `computed()`，嚴禁在 `ngOnChanges` 或 `ngDoCheck` 中手動賦值。
  - **UI 狀態**：元件內部的局部狀態，強制使用 `signal()`，禁止為簡單 UI 切換宣告 `BehaviorSubject`。

## 2. RxJS 與非同步處理規範 (Async & RxJS Strictness)

> **⚠️ 硬性規定：此為防範 Memory Leak 與 Race Condition 的最高指導原則。**

- **嚴禁訂閱地獄 (No Nested Subscribes)**：絕對禁止在 `subscribe()` 內部再次呼叫另一個 `subscribe()` 或執行非同步邏輯。必須使用 Higher-Order Mapping Operators (`switchMap`, `mergeMap`, `concatMap`, `exhaustMap`) 來串接非同步流程。
- **強制自動退訂 (Memory Leak Prevention)**：
  - **首選**：在 Template 中搭配 `| async` pipe，或在 TypeScript 中使用 `toSignal()` 將 Observable 轉為 Signal，交由 Angular 自動管理訂閱生命週期。
  - **次選**：若必須在 TypeScript 中呼叫 `.subscribe()`，**絕對必須**加上 `takeUntilDestroyed()` 確保元件銷毀時自動退訂。
- **Service 邊界**：HTTP Service 的方法必須回傳 `Observable<T>`。嚴禁在 Service 內部直接 `.subscribe()` 後將值賦予給類別變數。資料流的啟動必須由 Component 決定。

## 3. 狀態管理策略 (State Management)

> **⚠️ 硬性規定：必須嚴格依據 PM (01) 交接單中指定的狀態管理策略執行。**

- **情境 A：中小型專案 (交接單指定 Service + Signals)**
  - 嚴禁引入 NgRx。
  - **單一資料源**：在 Service 中使用 `signal()` 或 `BehaviorSubject` 儲存狀態。
  - **唯讀暴露**：Service 只能向外暴露唯讀的 `Signal` (使用 `.asReadonly()`) 或 `Observable`。
  - **狀態變更**：Component 必須呼叫 Service 提供的明確方法來改變狀態，禁止 Component 直接修改 Service 內的變數。

- **情境 B：大型複雜專案 (交接單指定 NgRx)**
  - 嚴守「Smart / Dumb Component」架構。Component 只能做兩件事：透過 `Store.selectSignal()` 讀取狀態，與 `Store.dispatch()` 發送 Action。
  - **嚴禁副作用**：Reducer 必須是純函數（Pure Function），任何牽涉到 API 呼叫、路由跳轉的副作用邏輯，**只能**寫在 Effects 中。
  - **Facade Pattern**：複雜模組必須建立 `xxx.facade.ts` 封裝 Store 的 select 與 dispatch，Component 只與 Facade 互動，嚴禁直接注入 Store。

## 4. 路由機制與架構約定 (Routing & Architecture)

- **目錄職責**：`app.routes.ts` 與 Route Shell Component 只負責路由入口、版面組裝、Guards/Resolvers 掛載與錯誤分流。實際業務區塊與細部 UI 應下放到 feature 目錄或 `components/sections`，禁止把完整頁面細節全部塞進 route entry component。
- **延遲載入 (Lazy Loading)**：路由必須採用 Lazy Loading。使用 `loadComponent` 載入單一元件，或使用 `loadChildren` 載入子路由群組，嚴禁在全域路由直接 import 元件實體。
- **路由路徑語法**：Route config 內的一般 path 使用 `kebab-case`；動態參數使用 `:id` 形式，fallback route 使用 `**`，禁止自行用魔法字串拼接未註冊路由。
- **集中式靜態路由表 (Centralized Routing Table)**：
  - **禁止硬編碼路徑**：Template 的 `[routerLink]`、TypeScript 的 `router.navigate()`，嚴禁直接散落 magic string path。
  - **統一引用**：導覽邏輯必須從專案路由常數檔（例如 `src/constants/routes.ts`）引用路徑定義。
  - **i18n 與 Breadcrumb 綁定**：多語系導覽與麵包屑應優先讀取路由定義或 Route `data` 中的 metadata。
- **Route Shell 極簡化 (Thin Page)**：Route entry component 應盡量保持輕薄，只處理 section 組裝與必要的 facade 呼叫。
- **HTTP 攔截器 (Interceptors)**：所有的 API Token 注入、全域錯誤攔截 (如 401) 必須寫在 HTTP Interceptor 中。
- **檔案命名規範**：嚴格遵守 Angular CLI 慣例 (`*.component.ts`, `*.service.ts`)。

## 5. UI 實作與生態系綁定 (UI & Ecosystem)

- **UI 基礎庫 (PrimeNG)**：本專案 Angular 預設搭配 **`PrimeNG`**。
  - AI 在新增 UI 時，必須優先使用 PrimeNG 的元件（如 `p-button`, `p-table`）。
  - **樣式整合**：採用 PrimeNG 的無樣式模式 (Unstyled) 或 Tailwind 覆寫機制。請嚴格套用 `03 UI Agent` 規格書開出的 Tailwind Tokens，禁止寫死傳統 CSS 色碼。
- **圖示庫 (Icons)**：優先使用 PrimeIcons (`pi pi-xxx`)，若專案有指定 Lucide 等第三方庫，依交接單指示為主。
- **動畫庫**：複雜動畫優先使用 `@angular/animations`。禁止直接用 `document.querySelector()` 手動操作 DOM。
- **樣式隔離**：預設使用 `ViewEncapsulation.Emulated`。若必須修改 PrimeNG 底層樣式，優先透過全域 CSS 變數覆寫，嚴禁濫用 `::ng-deep`。

## 6. 環境變數與環境隔離 (Environment & I/O)

- **API URL 切換**：禁止在 Service 內硬編碼 base URL。Client Bundle 應統一讀取 `src/environments/environment*.ts` 或專案封裝的 runtime config。
- **Angular 專屬 Router API**：導頁或讀取路由狀態，必須使用 `Router`、`ActivatedRoute`。**禁止**直接操作 `window.location`，也禁止手刻 query string parser。

## 7. 專案歷史遺留與架構約定 (Legacy & Project Conventions)

> **注意：尊重既有程式碼是不可侵犯之底線。**
- **沿用既有結構與拼寫**：在接手既有專案時，若發現目錄、檔案或變數命名存在歷史遺留的拼字錯誤或特殊慣例，在 import 或新增關聯檔案時，**絕對必須沿用現況**。嚴禁 AI 擅自「修正」拼寫並建立新目錄，導致專案出現雙軌並行的混亂狀況。若需重構，必須由人類開發者明確授權。

## 8. 響應式表單與資料驗證 (Typed Reactive Forms)

- **強型別表單優先 (Strict Typing)**：建立表單時，必須使用 Angular 強型別 `FormGroup`、`FormControl`。禁止宣告為 `any` 或 `UntypedFormGroup`。
- **禁止 Template-Driven Forms**：在複雜業務表單中，**嚴禁使用 `[(ngModel)]`**。表單狀態與驗證邏輯必須保留在 TypeScript 中。
- **驗證與錯誤回饋**：
  - 必須將 BA (02a) 定義的業務限制與 DBA/API (02b) 定義的欄位契約實作為 Angular `Validators`。
  - 表單錯誤提示 UI，必須對齊 `03 UI Agent` 定義的視覺狀態。
