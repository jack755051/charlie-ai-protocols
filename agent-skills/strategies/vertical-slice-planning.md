# Strategy: Vertical Slice Planning (垂直切片計畫法)

> 整合自外部 `engineering/to-prd` 的模組草圖思路 + `engineering/tdd` 的 tracer bullet 概念；CAP 內當作 **methodology strategy**。要解決的問題：把「大功能」拆成可以一片片端到端落地的垂直 slice，避免「先寫完所有後端再串前端」這種 horizontal layering 失控。

## 1. 適用情境 (When To Use)
- 接到使用者「要做 X 功能」的需求，需要產出 PRD / TechPlan / 派工計畫。
- 任務範圍跨多個 layer（UI / API / DB / 整合 / 測試）且時間表會超過一個 commit。
- 需要識別「哪些 module 要新建 / 修改」、「哪些是 deep module 機會」、「測什麼」、「先後順序」。

不適用：trivial bugfix、單一 layer 的小調整、純文件更新。

## 2. 核心理念 (Core Idea)
- **Slice 垂直，不切水平**。一個 slice = 從使用者觸發到資料持久化、含 happy path 測試的最小可運作端到端段落。
- **Tracer bullet 第一槍**：第一個 slice 不求功能完整，求把整條鏈路打通（UI → service → DB → test）。後面的 slice 才一個一個堆需求上去。
- **Deep module > shallow façade**：規劃時主動找「小 interface、深實作」的機會（對齊 `architecture-deepening.md`）。
- **Glossary first**：所有 PRD / TechPlan / Module 命名都用 `CONTEXT.md` 的 domain 詞彙（對齊 `shared-language-and-adr.md`）。
- **Test 規劃在 PRD 層，執行在 TDD 層**：本 strategy 決定**測什麼 module**；`tdd-vertical-slice.md` 決定**怎麼按節奏寫 test**。

## 3. Workflow

### 3.1 Read Context First
動工前讀齊：
- 使用者初始需求（PRD / 對話）
- `CONTEXT.md` / domain glossary
- 影響範圍內的既有 ADR（不要重新爭辯 settled 的決策）
- 既有 codebase：哪些 module 已存在、哪些 seam 可重用

### 3.2 Sketch Modules
把要新建或修改的 **major module** 列出來。每個 module：
- **Name**：用 glossary 詞彙（`Order intake module`，不是 `OrderHandler`）。
- **Interface（粗）**：caller 必須知道的最小集合。**不寫 type 簽章**，寫 invariant / error mode / ordering 期待。
- **Depth signal**：這是 deep module 機會還是 shallow wrapper？deletion test 預測會發生什麼。
- **Test surface**：interface 上哪些行為值得測（不是 implementation step）。

跟使用者確認：
- [ ] Module 切分對嗎？
- [ ] 哪些 module 要寫 test、哪些先不？
- [ ] 哪些 module 需要 ADR（hard-to-reverse / surprising / real trade-off 三條）？

### 3.3 Slice the Work Vertically
把整個功能切成一系列 vertical slice，每個 slice 必須：
- **End-to-end**：從觸發點到持久化（或可觀察結果），不停在某 layer。
- **Smallest viable**：能 demo 一件事就好，不求完整。
- **Test-bearing**：至少一條行為層的 test 跟著 slice 走（對齊 `tdd-vertical-slice.md` 的 tracer bullet）。
- **Independently shippable**：理想上每個 slice 自己一個 commit / PR。

第一片 slice = **tracer bullet**：證明整條鏈路能跑通；UI 可以是 placeholder、邏輯可以是 stub，但 happy path 從頭到尾要連得上。

之後的 slice 一個一個加：edge case、權限、validation、UX 細節、效能保護。每片 slice 對應 PRD 的某幾條 user story。

### 3.4 Output the PRD / TechPlan
**PRD 結構**（簡化自 to-prd skill 模板，根據 CAP 的 02a-BA / 02-TechLead 角色裁剪）：
- **Problem Statement** — 從使用者視角的痛點。
- **Solution** — 從使用者視角的解法。
- **User Stories** — long, numbered list，每條 `As an <actor>, I want <feature>, so that <benefit>`。
- **Slices** — 把 user stories 分組成 vertical slice，標明每片 slice 的範圍與順序（tracer bullet 是哪片）。
- **Module Sketch** — Step 3.2 的成果。
- **Testing Decisions** — 每個 module 的 test surface、測 behavior 不測 implementation、引用既有 prior art。
- **Out of Scope** — 明確排除。
- **ADR Triggers** — 哪些決策符合三條鐵律、需要開 ADR。

**禁止**：寫具體 file path 或 code snippet（容易過期）；寫 horizontal step list（"先做後端再做前端"）。

### 3.5 Hand Off to Execution
- 確認使用者同意切片與順序後，把第一片 slice（tracer bullet）派工給對應實作 agent（前端 / 後端 / QA）。
- 實作 agent 拿到 slice 時必須掛載 `tdd-vertical-slice.md` 執行紅綠重構；watcher 稽核時對齊 `architecture-deepening.md` 確認 module depth。

## 4. 邊界與禁令 (Boundaries)
- **不要 horizontal slice**：`先寫完 DB → 再寫 API → 再寫 UI` 的計畫會被 reject。
- 不要在 PRD 寫 file path / code snippet。
- 不要把所有 user story 都灌進第一片 slice — 第一片必須是 tracer bullet 等級的最小集合。
- 不要繞過 glossary 自創 module 名稱（對齊 `shared-language-and-adr.md`）。
- 不要為「以後可能有」的需求設計 interface — 先做有信心需要的，剩下等下一個 slice 再加。

## 5. 與 CAP agent 的對應
- **01-Supervisor**：使用者初始需求進來時，先用本 strategy 產 PRD 草稿與切片計畫，再決定派工順序。
- **02-TechLead**：產出 TechPlan 時掛載；負責決定 module 切分、deep module 機會、跨模組 ADR 觸發。
- **04-Frontend / 05-Backend**：拿到 slice 任務時掛載；確認自己拿到的是垂直 slice 而不是「水平層」之後再進入 `tdd-vertical-slice.md`。

## 6. 驗收 (Success Criteria)
- 產出的計畫可以指出第一片 tracer bullet slice 的範圍。
- 每個 slice 都可以獨立 commit / PR；不存在「必須等另一片才能驗收」的依賴鎖。
- Module 命名用 glossary 詞彙；不存在 `XxxHandler` / `YyyService` 這種 implementation-flavored 名字（除非 glossary 真的這樣定義）。
- 計畫中有明示 ADR triggers（即使最後是 `(none)` — 也要明示思考過）。
- 計畫被使用者認可後，下游實作 agent 拿到的是 self-contained 的 slice 任務。
