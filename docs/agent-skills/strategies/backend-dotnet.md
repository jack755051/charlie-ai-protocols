# Strategy: .NET Core Backend Implementation (v1.0)

## 1. 核心架構約束 (Framework Standards)
- **強型別配置 (Options Pattern)**：嚴禁直接讀取 `_configuration["Key"]`。必須定義配置類並使用 `IOptions<T>` 進行注入。
- **依賴生命週期 (DI Lifetime)**：
  - `DbContext` 與 `Repository` 必須註冊為 **Scoped**。
  - 無狀態工具類、Mapping 配置應註冊為 **Singleton**。
- **非同步與取消標準**：
  - 所有 I/O 密集型方法名必須以 `Async` 結尾（如 `GetByIdAsync`）。
  - 方法必須接收並傳遞 `CancellationToken` 以支援請求取消。

## 2. 業務邏輯與分層 (Application Logic)
- **MediatR (CQRS) 選配機制**：
  - 若 PM 指派採用 CQRS：Controller 僅負責 `_mediator.Send(command)`。所有邏輯、事務控制必須位於 `IRequestHandler` 中。
- **物件映射 (Mapping)**：
  - 嚴禁在 Controller 手動賦值。必須使用 `AutoMapper` 或 `Mapster` 實作映射，並在 Service 層完成轉換。
- **防禦性校驗**：使用 `FluentValidation` 實作 `IValidator<T>`，並透過 MediatR Pipeline 實作自動驗證。

## 3. 數據庫與 EF Core 規範
- **樂觀併發 (Concurrency)**：
  - 所有可修改實體必須配置 `[Timestamp]` 屬性 (`RowVersion`)。
  - 更新操作必須處理 `DbUpdateConcurrencyException`。
- **配置分離 (Fluent API)**：
  - 嚴禁在 Entity 類中使用過多 Data Annotations。必須實作 `IEntityTypeConfiguration<T>` 並在 `OnModelCreating` 中定義。
- **Migration 守則**：執行 `Add-Migration` 後必須手動檢查 `Up()` 方法。**絕對禁止**手動更改資料庫架構。

## 4. API 規範與安全 (API & Security)
- **統一回傳與過濾**：
  - 實作全域 `ResultFilter` 或 `Middleware`，確保所有回傳（含 Error）包裹在 `ApiResponse<T>` 中。
- **結構化日誌 (Structured Logging)**：
  - 統一使用 `Serilog`。日誌中必須包含 `CorrelationId` 以利鏈路追蹤。
- **歷史遺留處理**：**絕對禁止**修正指定的歷史遺留目錄（如 `Properties/resquestSettings.json`）或特定拼寫錯誤的資料庫欄位名。