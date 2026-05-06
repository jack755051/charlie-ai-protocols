# Strategy: TDD Vertical Slice (紅綠重構 + 垂直切片)

> 改寫自外部 `engineering/tdd` skill；CAP 內當作 **methodology strategy**。本 strategy 與 `unit-test-frontend.md` / `unit-test-backend.md` 互補：那兩份規範**測什麼工具用什麼語法**；本份規範**怎麼按節奏寫測試**。

## 1. 核心理念 (Philosophy)
- **Tests verify behavior through public interfaces, not implementation details.** 代碼內部可以全改，測試不該改。
- **Good tests** 像規格書 — 一句話讀完就知道系統做什麼（`user can checkout with valid cart`）。Refactor 後仍 survive，因為它不在乎內部結構。
- **Bad tests** 黏實作 — mock 內部 collaborator、測 private method、繞 interface 直查 DB。警訊是：refactor 後 test 壞了但行為沒變。

## 2. 反 pattern：Horizontal Slicing (絕對禁止)
**不要把 RED 當「寫完所有 test」、把 GREEN 當「寫完所有 code」。** 這會產出 crap test：
- 測想像中的行為，不是真實行為。
- 測 shape（資料結構、function signature）而非 user-facing 行為。
- 對真正的變化不敏感 — 行為壞了還是 pass，行為對了反而 fail。
- 在搞清楚實作前就 commit 到 test 結構，超出 headlights。

```text
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
```

## 3. Workflow

### 3.1 Planning
- 探索 codebase 時對齊 domain glossary（`shared-language-and-adr.md`），讓 test 名稱 / interface 詞彙跟既有語言一致；尊重該區域的 ADR。
- 動工前確認：
  - [ ] 跟使用者確認需要哪些 interface 變更
  - [ ] 跟使用者確認哪些行為要測（**排序優先級**）
  - [ ] 找 deep module 機會（小 interface、深實作）
  - [ ] 為 testability 設計 interface
  - [ ] 列出要測的 **行為**（不是實作步驟）
  - [ ] 拿到使用者對計畫的同意
- **沒辦法測完所有 case**。確認哪些行為**最重要**，把測試力氣放在 critical path 與複雜邏輯。

### 3.2 Tracer Bullet
寫 **一個** test 確認系統 **一件** 事：

```text
RED:   寫第一個行為的 test → 失敗
GREEN: 寫最少代碼讓它 pass → 通過
```

這就是 tracer bullet — 證明 end-to-end 路徑可走通。

### 3.3 Incremental Loop
每個剩下的行為：
```text
RED:   寫下一個 test → 失敗
GREEN: 最少代碼讓它 pass → 通過
```
規則：
- 一次只一個 test
- 只寫剛好過 **本次** test 的代碼
- 不要 anticipate 未來的 test
- Test 聚焦在可觀察的 **行為**

### 3.4 Refactor (只在 GREEN 後)
所有 test pass 後找 refactor candidate：
- [ ] 抽 duplication
- [ ] Deepen module（把複雜度藏在簡單 interface 後 — 對應 `architecture-deepening.md`）
- [ ] SOLID（自然出現時才套，別硬推）
- [ ] 想想新代碼揭示了什麼 about 既有代碼
- [ ] 每一步 refactor 都跑 test
- **絕對不要在 RED 狀態 refactor。先 GREEN。**

## 4. 每輪 Cycle 的 Checklist
- [ ] Test 描述行為，不描述實作
- [ ] Test 只用 public interface
- [ ] Test 在 internal refactor 後仍 survive
- [ ] 代碼是 **本次 test** 的最小集合
- [ ] 沒新增「以後可能用到」的功能

## 5. 邊界與禁令 (Boundaries)
- 不要 horizontal slice。
- 不要在 RED 重構。
- 不要 mock internal collaborator 來繞 interface。
- 不要在尚未確認重要行為前先寫一堆 trivial test 充數。
- 整合測試（integration-style）優先於 unit-with-everything-mocked。

## 6. 與 CAP agent 的對應
- **04-Frontend / 05-Backend**：實作任務時掛載；對齊 `unit-test-frontend.md` / `unit-test-backend.md` 的 framework 規範執行 vertical slice。
- **07-QA**：產出 integration / E2E test 時掛載；對齊 `qa-playwright.md` / `qa-k6.md`。
- **90-Watcher**：稽核 test 是否真的測 behavior、是否落入 horizontal slice、refactor 是否在 RED 期間發生。

## 7. 驗收 (Success Criteria)
- 交付的代碼可以指出 RED→GREEN 的時序記錄（commit history 或 PR description）。
- 每個 test 名稱讀起來像規格句子，不像實作敘述。
- 沒有「測了 internal helper」這種 case；都從 public interface 進去。
- 對應的 `unit-test-*.md` 與 `qa-*.md` framework 規範都遵守了。
