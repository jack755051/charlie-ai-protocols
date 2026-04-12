# Strategy: NestJS Backend Implementation (v1.0)

## 1. 模組化與依賴注入 (Modular Architecture)
- **嚴格模組邊界**：每個 Feature 必須具備獨立的 `*.module.ts`。嚴禁跨模組直接引用 Provider，必須透過 `exports` 與 `imports` 進行通訊。
- **建構子注入 (Constructor Injection)**：強制採用類建構子注入。嚴禁使用 `Reflector` 或手動 `moduleRef.get()` 獲取實例（動態模組特殊場景除外）。
- **Provider 抽離**：Repository 與 Service 必須標記為 `@Injectable()` 並在 Module 中定義，確保 DI 容器正確管理生命週期。

## 2. 請求處理生命週期 (Request Lifecycle)
- **DTO 驗證 (Validation)**：
  - 進入 Controller 前，必須定義 `*.dto.ts` 並使用 `class-validator` 裝飾器。
  - 全域必須掛載 `ValidationPipe`，並設定 `whitelist: true` (過濾未定義欄位) 與 `transform: true` (自動轉換型別)。
- **攔截器封裝 (Interceptors)**：
  - 統一使用全域 `TransformInterceptor` 將成功回傳結果封裝為標準的 `ApiResponse<T>`。
- **異常處理 (Exception Filters)**：
  - **嚴禁**在 Service 層直接拋出 `HttpException` (如 `NotFoundException`)。Service 僅允許拋出自定義的 `DomainException`。
  - 由全域 `HttpExceptionFilter` 負責將 `DomainException` 映射為對應的 HTTP 狀態碼與錯誤訊息。

## 3. 持久層實作 (Persistence with TypeORM/Prisma)
- **Repository Pattern**：
  - **強制自定義 Repository**：業務邏輯嚴禁直接呼叫 `EntityManager` 或原生 Repository 方法。必須封裝於專屬的 Repository 類中。
- **單元作業 (Unit of Work)**：
  - 涉及多表寫入時，必須使用 `DataSource` 的 `QueryRunner` 或 `cls-hooked` 模式管理 Transaction，確保原子性。
- **樂觀併發控制**：Entity 必須包含 `@VersionColumn()`。更新失敗時由 Filter 捕獲併發異常並回傳特定錯誤碼。

## 4. 命名與工程約定
- **檔案命名**：嚴格採用 NestJS 標準 `[name].[type].ts`（例：`user.service.ts`, `auth.controller.ts`）。
- **歷史拼寫守護**：若既有 API 路徑或 DTO 欄位存在錯誤（如 `resquestId`），**絕對禁止修正**，必須保持與前端契約一致。