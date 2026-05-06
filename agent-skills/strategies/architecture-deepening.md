# Strategy: Architecture Deepening (深化模組與 Seam 紀律)

> 改寫自外部 `engineering/improve-codebase-architecture` skill；CAP 內當作 **methodology strategy**。目標：讓 codebase 的 module 從 shallow 走向 deep — 高 leverage、好測試、AI 也容易導航。

## 1. 適用情境 (When To Use)
- 使用者要「改善架構 / 找重構機會 / 讓某個模組更好測 / 整合緊耦合的代碼」。
- diagnose-loop 結尾發現 bug 是因為「沒 correct seam 鎖死」、callers 太多、coupling 過深。
- TechLead / Supervisor 看到有人不停在同一塊代碼補 hotfix。

不適用：trivial 風格修飾、純 lint 修正、單行 bug fix、純功能新增（那是 vertical-slice-planning 的事）。

## 2. 必須對齊的詞彙 (Glossary — 嚴格使用)
這些詞在每個建議裡都要用一致。**不要**漂成「component / service / API / boundary」，那會讓討論失焦。

- **Module** — 任何具備 interface 與 implementation 的東西（function / class / package / 垂直 slice）。
- **Interface** — caller 必須知道的全部資訊：types、invariants、error mode、ordering、config。**不只**是 type signature。
- **Implementation** — 內部的代碼。
- **Depth** — interface 上的 leverage。**Deep** = 高 leverage（小 interface、深實作、大行為）。**Shallow** = interface 跟 implementation 一樣複雜。
- **Seam** — 一個 interface 所在的位置，可以在不改原地代碼的情況下改變行為。**用 seam，不要用 boundary。**
- **Adapter** — 滿足某個 seam 的具體實作。
- **Leverage** — caller 從 depth 拿到的好處。
- **Locality** — maintainer 從 depth 拿到的好處：變更 / bug / 知識集中在一處。

## 3. 三條核心原則 (Key Principles)

### 3.1 Deletion Test
想像把這個 module 刪掉。
- 複雜度消失 → 它是 pass-through，shallow，**candidate for deepening 或刪除**。
- 複雜度在 N 個 caller 重新冒出來 → 它在賺它的位置，**正在 earning its keep**。

### 3.2 The Interface Is The Test Surface
能不能 unit-test 一個 module，等於能不能描述清楚它的 interface。寫不出 test 的時候多半是 interface 本身定義不清，不是「不夠時間」。

### 3.3 One Adapter = Hypothetical Seam, Two Adapters = Real Seam
只有一個 adapter 的 seam 是想像中的 seam，是負債。真實有第二個 adapter（即使是 in-memory test fake）才證明這個 seam 是有價值的抽象。

## 4. 三段流程 (Process)

### 4.1 Explore
- 先讀 domain glossary / `CONTEXT.md` 與該區域 ADR（對齊 `shared-language-and-adr.md`）。
- 用 codebase 探索工具有機地走，**不要**死板套規則。記下你感受到摩擦的地方：
  - 理解一個概念要在多個小 module 之間跳來跳去。
  - module 是 shallow（interface 幾乎跟 implementation 一樣複雜）。
  - 「為了好測」抽出純 function，但 bug 都藏在「怎麼被 call」的地方（沒 locality）。
  - 緊耦合的 module 滲透出 seam。
  - 沒被測或透過現有 interface 難測的部分。
- 對每個可疑 shallow module 套 deletion test：刪了會集中複雜度，還是只是搬位置？「會集中」就是要的訊號。

### 4.2 Present Candidates
列出 numbered list of deepening opportunities。每個候選包含：
- **Files** — 涉及哪些 file / module。
- **Problem** — 現況為什麼產生摩擦（用 glossary 詞彙：interface 太細 / shallow / 沒 locality / 兩 module 共用同一條 invariant 卻無 seam）。
- **Solution** — 純文字描述會變成什麼樣（哪個 seam 出現、誰是新 module 的 interface、複雜度集中到哪去）。
- **Benefits** — 用 leverage / locality / testability 的詞彙說明，**禁止**寫「程式碼比較漂亮」這種非語意的話。

**ADR 衝突**：候選跟既有 ADR 矛盾 → 只在摩擦真的大到值得重啟 ADR 才提，並明確標 `contradicts ADR-XXXX — but worth reopening because…`。不要把 ADR 列為「永遠不能動」的禁區。

**先別**提 interface 細節，問使用者「哪個你想往下挖？」

### 4.3 Grilling Loop (使用者選了某個之後)
- 跟使用者一起走 design tree：constraints / dependencies / deepened module 的形狀 / seam 後面是什麼 / 哪些 test 會 survive。
- **副作用 inline 發生**，不 batch：
  - 用了 `CONTEXT.md` 沒收的詞 → 當場補（對齊 `shared-language-and-adr.md`）。
  - 模糊詞當場 sharpened → 當場改 `CONTEXT.md`。
  - 使用者拒絕候選且理由 load-bearing → 提議開 ADR（依 `shared-language-and-adr.md` 的三條鐵律）。
  - 想看 alternative interface → 換到 interface design 細節討論。

## 5. 邊界與禁令 (Boundaries)
- 不在 bug fix 進 commit **之前**做架構建議（先解決，後思考 — 對齊 `diagnose-loop.md` Phase 6）。
- 不要用 boundary / component / service 取代 seam / module — 詞彙漂移就讓討論失焦。
- 不要為了「漂亮」做 deepening。沒 leverage / locality 的提升就是 churn。
- 不要把每條 ADR 都當禁令；contradicts 不等於 forbidden，但要正面對話。
- 不要用 `subagent_type=Explore` 之外的高成本搜索做盲目大範圍掃描；先用 grep / glob，多輪 / 開放式才升級。

## 6. 與 CAP agent 的對應
- **02-TechLead**：架構評估、TechPlan 撰寫、跨模組重構建議的主要使用者。
- **01-Supervisor**：跨 agent 結案 / 大型重構決策時掛載；負責決定哪個 candidate 升 ADR、哪個直接派工。
- **90-Watcher**：稽核時挑出 shallow module 違規（pass-through wrapper、interface 跟 impl 同等複雜、單 adapter 假 seam）；標 `品質異常` 但不直接修。

## 7. 驗收 (Success Criteria)
- 提出的每個 deepening candidate 都通過 deletion test 並有 leverage / locality / testability 的具體論述。
- glossary 詞彙在整個建議裡用一致；沒漂成 boundary / component。
- ADR 衝突明確標示且只在摩擦大到值得 revisit 才提。
- 結束時若有實作落地，pre-existing test 在 deepening 後仍 survive（test surface 不被破壞）。
