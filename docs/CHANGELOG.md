# Changelog

## [1.0.1] - 2026-04-12
### Added
- 實作登入頁面與 Auth Facade (Angular)。
- 新增 PostgreSQL 使用者資料表 Schema。

### Fixed
- 修復 Watcher 發現的 `auth.service.ts` 內 `subscribe()` 未退訂導致的記憶體洩漏問題。
- 修正 API Response 的錯誤封裝格式。

### Changed
- 根據 SA 規格更新 User DTO 欄位，增加 `last_login_at`。