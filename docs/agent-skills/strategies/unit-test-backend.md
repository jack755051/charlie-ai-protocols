# Strategy: Backend Unit Testing (v1.0)

> 本文件定義後端開發者 (05) 撰寫單元測試的標準。單元測試屬於白箱測試，由實作者自行負責，與 QA (07) 的整合/E2E/壓測互不重疊。

## 1. 職責邊界與測試金字塔定位 (Scope)

> **⚠️ 硬性規定：單元測試由 Backend Agent (05) 產出，嚴禁推卸給 QA Agent (07)。**

- **你的範圍**：Domain 層業務規則、Application 層協調邏輯、DTO/Entity 映射轉換。
- **不在你的範圍**：API 契約驗證 (Integration)、跨服務端到端流程 (E2E)、效能壓測 (k6)。這些由 QA (07) 負責。
- **產出要求**：每個 Application Service 與 Domain Model 必須伴隨對應的測試檔。

## 2. Mock 策略與隔離邊界 (Mock Boundary)

> **⚠️ 硬性規定：單元測試絕對禁止連線真實資料庫或呼叫外部 API。**

- **Repository / 持久層**：所有資料庫存取必須 Mock。NestJS 使用 `jest.mock()` 或自訂 Mock Repository；.NET 使用 `Moq` / `NSubstitute` Mock `IRepository<T>`。
- **Cache (Redis 等)**：快取層一律 Mock，嚴禁在測試中啟動真實 Redis 實例。
- **第三方服務**：外部 HTTP 呼叫（金流、簡訊、Email）一律 Mock，驗證呼叫參數與回傳處理即可。
- **Infrastructure 層全隔離**：單元測試的邊界止於 Application 與 Domain 層。Infrastructure 的所有實作細節必須透過介面 (Interface) Mock 替換。

## 3. 測試分層規範 (Testing Layers)

### 3.1 Domain 層 (核心業務規則)
- **驗證重點**：Rich Domain Model 的行為方法、業務規則驗證、狀態轉換邏輯。
- **核心斷言**：驗證業務規則違反時是否正確拋出 `DomainException`，以及例外訊息與錯誤碼是否精確。
- **純粹性要求**：Domain 測試嚴禁出現任何框架依賴（無 DI 容器、無 HTTP Context、無 DB Context）。

### 3.2 Application 層 (協調邏輯)
- **驗證重點**：Use Case / Command Handler 的協調流程（呼叫順序、條件分支、事務邊界）。
- **Mock 注入**：透過建構子注入 Mock 的 Repository、Cache 與外部服務，驗證 Service 的輸入輸出與副作用（如是否呼叫了 `repository.save()`）。
- **樂觀併發驗證**：模擬 `version` 欄位衝突情境，驗證是否正確拋出併發異常。

### 3.3 Mapper / DTO 轉換層
- **驗證重點**：Entity ↔ DTO 的映射正確性、欄位對齊、邊界值處理（null、空集合）。
- **SSOT 對齊**：轉換後的欄位名稱必須與 API 介面規格書（`<模組>_API_v<版號>.md`）100% 一致。

## 4. 框架特化規範 (Framework-Specific Rules)

#### IF [NestJS]：
- **測試工具**：使用 Jest。
- **模組隔離**：使用 `Test.createTestingModule()` 建立最小化測試模組，僅注入受測 Service 與其 Mock 依賴。嚴禁載入整個 `AppModule`。
- **DomainException 驗證**：使用 `expect(...).toThrow(DomainException)` 驗證業務異常，嚴禁在測試中捕獲 `HttpException`（那是 Filter 的責任）。
- **命名慣例**：測試檔命名 `*.spec.ts`，與原始碼同層放置。

#### IF [C# .NET]：
- **測試工具**：使用 xUnit + Moq / NSubstitute。
- **Arrange-Act-Assert (AAA)**：每個測試方法必須嚴格遵守 AAA 結構，禁止在單一測試中混合多個 Act。
- **CancellationToken 傳遞**：測試呼叫 `Async` 方法時必須傳入 `CancellationToken.None`，確保方法簽名正確。
- **命名慣例**：測試類別命名 `{ClassName}Tests.cs`，方法命名 `{Method}_Should{ExpectedBehavior}_When{Condition}`。
- **測試專案分離**：測試程式碼必須放在獨立的 `*.Tests` 專案中，嚴禁與業務程式碼混合。

## 5. 專案慣例與遺留守護 (Legacy & Conventions)

- **歷史拼寫守護**：測試中引用的路徑、DTO 欄位若存在歷史遺留拼寫（如 `resquestId`），必須原樣沿用，嚴禁在測試中「修正」。
- **Schema 對齊**：測試資料的欄位結構必須與資料庫事實檔案（`<模組>_schema_v<版號>.md`）保持一致。
