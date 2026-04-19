# Changelog

## [1.0.4] - 2026-04-19
### Added
- 為 `03-ui-agent` 建立第一階段可維護設計資產輸出規範，主交付物包含 `UI Spec`、`tokens.json`、`screens.json` 與 `prototype.html`。

### Changed
- 同步調整 Supervisor、Frontend、Watcher、Logger 與 `AGENTS.md`，使 UI 設計資產交接、稽核與紀錄流程對齊第一階段輸出格式。

## [1.0.3] - 2026-04-19
### Added
- 為 Supervisor、Tech Lead、BA、DBA、SRE 與 Logger 補上標準化交接摘要欄位與紀錄模式欄位，統一單次任務與編排流程的交接格式。

### Changed
- 將 Logger 升級為分級紀錄機制，明確區分 `trace_only` 與 `full_log`，並要求單獨呼叫 Agent 時也必須保留 Trace Log。
- 調整 Supervisor 的派單規則，要求所有明確交付完成後先補 Trace，再依 `run_mode` / `record_level` 決定是否升級寫入 Devlog 與 `CHANGELOG`。

## [1.0.2] - 2026-04-19
### Added
- 為 DevOps Agent 補上標準化交接摘要欄位，統一部署與 CI/CD 任務完成後的交接格式。

### Changed
- 明確定義 DevOps 任務的 `record_level` 升級規則，將正式部署與基礎設施變更歸類為 `full_log`。

## [1.0.1] - 2026-04-12
### Added
- 實作登入頁面與 Auth Facade (Angular)。
- 新增 PostgreSQL 使用者資料表 Schema。

### Fixed
- 修復 Watcher 發現的 `auth.service.ts` 內 `subscribe()` 未退訂導致的記憶體洩漏問題。
- 修正 API Response 的錯誤封裝格式。

### Changed
- 根據 SA 規格更新 User DTO 欄位，增加 `last_login_at`。
