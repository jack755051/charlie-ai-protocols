# CAP Workflow Constitution (v0.1 Draft)

> 本文件為 CAP 在 `workflow` 層級的最高治理原則（編排憲法）。
> 它不取代 `agent-skills/00-core-protocol.md`，而是與其互補：
> - `00-core-protocol.md` 管 **單一 Agent 的角色邊界、行為紀律與品質底線**
> - 本文件管 **多 Agent workflow 的編排深度、成本上限、交接密度與停止條件**

---

## 1. 定位與權威順序

### 1.1 本文件的定位

- 本文件是 **workflow 編排層的最高憲法**。
- 它的目標不是增加流程官僚性，而是以**最小必要限制**，對以下風險施加最嚴格影響：
  - token 消耗失控
  - phase 無限制膨脹
  - 長文檔逐步堆疊導致耗時失控
  - 非正式規劃被誤跑成完整規格流水線
  - 下游被不必要全文上下文污染

> **命名澄清（避免與 `schemas/workflows/project-constitution.yaml` 混淆）**：
> 本文件管「runtime 跑 workflow 應遵守哪些規則」，是元憲法層；
> `schemas/workflows/project-constitution.yaml` 是一條具體的 workflow，**用來產出 repo 級 Project Constitution 文件**，本身受本文件約束。
> 兩者不同層級。詳細的 5 個 constitution 相關檔職責對照見 `workflows/project-constitution-memo.md` §術語對照。

### 1.2 權威順序

若規則發生衝突，權威順序如下：

1. 使用者明確指令
2. `agent-skills/00-core-protocol.md`
3. 本文件 `workflow-constitution.md`
4. `schemas/workflows/*.yaml`
5. 個別 agent prompt / 局部策略文件

> 結論：workflow schema 不是最高權威；若 schema 合法但違反本文件，runtime 應以本文件為準。

---

## 2. 與 00 憲法的分工

### 2.1 本文件不重複管理的事項

以下事項已由 `00-core-protocol.md` 管理，本文件不重複立法：

- 單一 Agent 的角色邊界
- 溝通語言
- 動手前觀察與破壞性操作限制
- 自我反思迴圈
- 一般性交接摘要格式

### 2.2 本文件新增治理的事項

本文件專管以下「編排層」問題：

- workflow 預設最多應跑多深
- phase 何時必須停止
- 上下文應以全文還是摘要往下傳
- 哪些產物可以在目前階段生成
- 哪些 step 必須降級為 optional
- token / 時間 / 產物體積失控時，應如何降級

---

## 3. 立法原則：最小限制，最大約束

### 3.1 最小限制原則

- 本文件只限制會對成本、速度、可維護性造成結構性傷害的編排行為。
- 不以「規則越多越安全」為目標。
- 不干涉單一步驟內的專業輸出細節，除非該細節會導致整體 workflow 膨脹。

### 3.2 最大影響原則

一旦下列結構性風險成立，本文件的限制必須立即生效：

- 長文檔被完整傳遞到下游
- 非正式規劃自動展開為 BA / DBA / UI / QA 全套
- 設計資產（JSON / HTML / DB schema / mock payload）在錯誤階段被提前生成
- workflow 只是「每個 agent 都寫一份長報告」

---

## 4. Workflow 鐵律

### 4.1 最小充分原則 (Minimum Sufficient Workflow)

- workflow 預設只能啟動**完成當前使用者目標所需的最少 steps**。
- 若使用者要求的是：
  - `非正式規劃`
  - `初步評估`
  - `先不要實作`

  則預設上限為：

1. `prd`
2. `tech_plan`

- `ba`、`dba_api`、`ui`、`qa`、`watcher` 等後續 step 必須視為 **opt-in**，不得自動展開，除非：
  - 使用者明確要求
  - 上游 step 明確標示「現階段若不展開，目標無法完成」

### 4.2 停止即成功原則 (Stop When Goal Is Satisfied)

- workflow 不得因為「schema 裡還有下一步」就繼續推進。
- 若當前目標已達成，runtime 必須允許提早結束。
- 「完成目標」的判斷優先於「完成所有 phase」。

### 4.3 摘要傳遞原則 (Summary-First Handoff)

- 下游 step 預設只能讀取：
  - `handoff summary`
  - 必要 metadata
  - 必要 artifact path

- 下游不得預設讀取完整上游全文，除非：
  - 該 step 的能力本質需要全文（例如 spec audit / final review）
  - runtime 能證明摘要不足以安全執行

### 4.4 全文傳遞舉證責任

- 任何 step 若要吃完整上游文檔，必須有明確理由。
- 舉例：
  - `watcher / spec_audit` 可合理要求全文
  - `ui` 不應預設吃完整 `prd + tech_plan + ba + dba_api` 全文；應先吃壓縮 handoff

### 4.5 產物分級原則 (Artifact Tiering)

每個正式 step 至少應區分兩級輸出：

1. `full artifact`
2. `handoff summary`

建議可擴充第三級：

3. `machine metadata`

規則如下：

- 人閱讀與正式留存讀 `full artifact`
- workflow 下游預設只吃 `handoff summary`
- runtime 綁定、檢查與路由讀 `machine metadata`

### 4.6 階段適配原則 (Stage-Appropriate Outputs)

- 在 `非正式規劃` 階段，禁止預設生成以下重型資產：
  - 完整 Design Tokens JSON
  - Screens JSON
  - Prototype HTML
  - DB schema 細表
  - 大型 API mock payload
  - 實作級 DTO

- 此類資產只能在：
  - 使用者明確要求
  - workflow 階段已進入「正式規格」或「實作準備」
  時才允許生成。

### 4.7 Optional 必須真 Optional

- `optional: true` 不得只是 schema 裝飾。
- optional step 若未被使用者要求，或上游未明確觸發，不得自動執行。
- runtime 必須允許 optional step 在無損主目標的前提下直接跳過。

### 4.8 預算治理原則 (Budget Governance)

workflow 必須受以下三種預算約束：

1. `step_count_budget`
2. `artifact_size_budget`
3. `context_budget`

當任一預算逼近上限時，runtime 應優先採取：

1. 改傳摘要
2. 跳過 optional
3. 延後資產生成
4. 提前結束 workflow

而不是繼續堆疊 phase。

### 4.9 串行審慎原則

- 串行 phase 成本會逐步放大。
- 若某一步的主要作用只是「延伸說明」而非「解鎖下一步」，應優先延後或移除。
- 不得把所有專家 step 都視為主線必經。

### 4.10 終端精簡原則

- CLI / terminal 的職責是顯示：
  - phase
  - step
  - live status
  - 簡短章節進度
  - 輸出路徑

- 完整文檔不得在終端完整灌出。
- 長內容只允許寫入 artifact，不得直接刷滿終端。

---

## 5. 強制降級條件

若 workflow 出現以下任一情況，runtime 必須強制降級：

### 5.1 文檔膨脹

任一步產物若顯著超過當前階段合理範圍（例如非正式規劃輸出接近完整規格書），後續 step 只能吃摘要，不得再吃全文。

### 5.2 上下文遞增失控

若後續 step 的輸入集合呈現：

```text
原始需求 + 全部上游全文
```

則 runtime 必須插入 summary handoff，而非直接放行。

### 5.3 產物型別過重

若當前階段不是「正式規格」或「實作準備」，卻開始生成：

- JSON schema
- HTML prototype
- 大型表格
- 大量 mock payload

則 runtime 應中止該 step 或把其改寫為摘要版。

---

## 6. Runtime 應有責任

### 6.1 Runtime 不是被動執行器

`cap workflow plan / bind / run` 不得只是盲目照 schema 逐步執行。
Runtime 必須扮演治理者，至少要能判斷：

- 現在是否跑太深
- 是否應該提早停
- 是否應把全文轉成摘要
- 是否應該跳過 optional

### 6.2 Runtime 至少應維護以下欄位

每個 step 至少應可被追蹤以下治理資訊：

- `requested_by`
- `goal_stage`
- `input_mode` (`summary` / `full`)
- `output_tier`
- `continue_reason`
- `budget_state`

### 6.3 Runtime 必須能記錄「為什麼繼續」

每個非初始 step，都必須可追溯：

- 為何啟動
- 為何沒有停止
- 為何沒有降級

若無法回答，代表該 step 不應被執行。

---

## 7. Workflow 階段模型

建議將 workflow 粗分為四層：

1. `informal_planning`
2. `formal_specification`
3. `implementation_preparation`
4. `implementation_and_verification`

治理規則如下：

- `informal_planning`
  - 只允許輕量規劃與高階建議
  - 預設上限：`prd + tech_plan`

- `formal_specification`
  - 才允許 BA / DBA / UI 系統化展開
  - 仍應採 summary-first handoff

- `implementation_preparation`
  - 才允許 tokens / screens / prototype / schema 等資產分拆落地

- `implementation_and_verification`
  - 才進入 frontend / backend / qa / audit 全鏈

---

## 8. 違憲訊號

若 workflow 出現以下任一訊號，應視為違反本憲法：

1. 使用者只要「初步規劃」，卻自動跑完整規格鏈
2. 下游預設吃全部上游全文
3. terminal 出現大段完整規格輸出
4. UI step 輸出內容大於前四步總和的顯著比例
5. artifact 的主要內容是為了「讓下一步看起來完整」，而不是為了完成當前目標
6. optional step 沒被要求卻仍執行
7. workflow 無法解釋為何還要繼續下一步

---

## 9. 對現況的直接約束

依本文件 v0.1 草案，以下行為應立即視為不建議：

- 不應在未明確授權下自動展開大型或多階段 workflow
- `ui` 在非正式規劃階段直接 inline 輸出 Tokens JSON / Screens JSON / Prototype HTML
- 任一步將完整上游四份以上文檔直接灌入 prompt

---

## 10. 最小落地建議

若要把本文件落地到 runtime，最小可行改動順序如下：

1. 在 workflow metadata 增加 `goal_stage`
2. 為每個 step 增加 `output_tier`
3. 產生 `handoff-summary.md`
4. runtime 預設使用 `summary` 而非 `full` 作為下游輸入
5. 對 `informal_planning` 施加 phase 上限

---

## 11. 結論

本文件的核心立場只有一句話：

> workflow 應以最小必要步驟完成使用者目標，而不是把所有可用 agent 依序跑完。

若 `00-core-protocol.md` 保證的是「單兵不越界」，
本文件保證的就是「整條編排鏈不失控」。
