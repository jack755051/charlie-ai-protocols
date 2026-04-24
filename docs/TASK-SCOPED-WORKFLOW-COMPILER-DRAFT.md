# Task-Scoped Workflow Compiler 草案

> 本文件定義 CAP 下一階段的 runtime 方向：不再先選固定 workflow 再硬跑，而是依單次任務動態產生最小可執行 workflow。
> 狀態：draft。

## 為什麼要有這份草案

目前的 workflow 模型比較適合：

- 已知流程
- 已知角色
- 已知產物
- 已知 skill availability

但實際任務常常不是這樣。更常見的是：

- 使用者先丟一句話需求
- 技術邊界不完整
- skill pool 不一定齊全
- 不確定是否真的需要 BA / DBA / UI / QA 全部展開
- 若上游產物不完整，下游不應該繼續燒 token

因此需要把 runtime 升級成：

**task-scoped workflow compiler**

也就是：

- 先理解任務
- 再推導需要哪些 capability
- 再看 skill 能不能支援
- 最後才編譯出本次真正要跑的最小 workflow

## 完整 9 步

前面提到的「3 到 9」看起來像 7 步，是因為省略了前兩步。完整版本如下：

1. **一句話需求輸入**
   - 使用者只需要提供任務目標與粗略方向

2. **有限反問**
   - 只追問會阻止 workflow 建構的資訊
   - 例如：成功條件、技術限制、是否需要 UI、是否允許 fallback

3. **產出任務憲法 (Task Constitution)**
   - 定義本次任務的目標、範圍、非目標、成功條件、風險、可接受 fallback、停止條件

4. **推導 capability graph**
   - 從任務憲法推導本次任務需要哪些 capability
   - 先得到語意圖，而不是先固定 workflow

5. **skill binding**
   - 到 skill pool / registry 將 capability 綁定到可用 skill
   - 產出 `ready / degraded / blocked`

6. **unresolved policy 決策**
   - 對缺 skill 的 capability 做正式決策
   - 例如：fallback / generate_agent / pending / re-scope

7. **編譯最小可執行 workflow**
   - 把 capability graph + binding result 編譯成真正要跑的最小 workflow
   - 不是所有 capability 都一定要展開成 step

8. **執行**
   - 交由 executor 跑 bound workflow

9. **每步 input/output gate + blocked state**
   - step 開始前檢查 input artifact
   - step 結束後檢查 output artifact
   - 缺輸入就 `blocked`
   - 缺輸出就 `hard_fail`
   - 只有 `validated` 的 step 才能解鎖下游

## 一句話總結

這不是「先寫 workflow 再跑」。

這是：

**task constitution -> capability binding -> workflow compile -> execution**

## 核心物件

### 1. Task Constitution

本次任務的治理基準。至少應包含：

- `goal`
- `scope`
- `non_goals`
- `success_criteria`
- `constraints`
- `risk_profile`
- `allowed_fallbacks`
- `stop_conditions`
- `output_expectations`

### 2. Capability Graph

從任務憲法推導出的能力圖，而不是 step 清單。至少包含：

- `capability_name`
- `required / optional`
- `depends_on`
- `expansion_condition`
- `artifact_requirements`

### 3. Binding Report

每個 capability 綁定結果：

- `resolved`
- `fallback_available`
- `required_unresolved`
- `optional_unresolved`
- `incompatible`

### 4. Compiled Workflow

本次真正要執行的最小 workflow。它是編譯結果，不是預先寫死的模板。

## 為什麼這比固定 workflow 更好

### 1. 避免過早展開

例如小工具任務，不一定需要：

- BA
- DBA/API
- UI
- QA
- DevOps

若 `tech_plan` 已能明確指出：

- 只是 CLI 小工具
- 不需要資料庫
- 不需要 UI
- 先做 spike 即可

那 runtime 應該停在較早 phase，而不是硬跑完整規格鏈。

### 2. skill 缺失時不會假裝能跑

如果 capability graph 需要 Rust specialist，但 registry 沒有：

- 不應該先編譯出完整 delivery workflow 再失敗
- 應在 binding / unresolved policy 階段就停住或縮 scope

### 3. 問題要在根因附近停止

如果 A 應產出 artifact `F`，而 C 需要 `F`：

- A 沒有正常產出 `F`
- C 應直接標成 `blocked_missing_input`
- 不應該讓 C 繼續跑

這就是 runtime 必須有的 **artifact-aware fail-fast**。

## 與現有 CAP 結構的對應

### 可保留

- `schemas/capabilities.yaml`
- `.cap.skills.yaml` / `.cap.agents.json`
- `RuntimeBinder`
- `workflow_loader.build_semantic_plan()`
- 現有 workflow schema 的 `needs / inputs / outputs / governance`

### 需要新增或升級

#### 1. Task Constitution Layer

新增一層 task-scoped 結構，位於 workflow 之前。

#### 2. Capability Graph Builder

從 task constitution 動態產生 capability graph。

#### 3. Workflow Compiler

把 capability graph + binding report 編譯成最小 workflow。

#### 4. Step State Machine

至少要有：

- `pending`
- `running`
- `validated`
- `soft_fail`
- `hard_fail`
- `blocked`
- `skipped`

#### 5. Artifact Gate

step 執行前：

- 驗證 required inputs 是否存在且來源 step 狀態為 `validated`

step 執行後：

- 驗證 required outputs 是否存在
- 驗證輸出最小格式是否成立

## Exit Policy

這套 runtime 若要穩，不能只有「失敗就停」這麼簡單，至少要有四層 exit：

### 1. Planning Exit

在反問 / 任務憲法階段就停止：

- 需求不清
- 成功條件不明
- 關鍵限制缺失
- 高風險且無法判定

### 2. Binding Exit

在 skill binding / unresolved policy 階段停止：

- required capability 沒 skill
- 沒有 fallback
- 風險不允許 generic 代理

### 3. Pre-dispatch Exit

在 step 開始前停止：

- 缺少 required input artifact
- handoff 不完整
- gate prerequisite 不成立

### 4. Post-step Exit

在 step 結束後停止：

- exit 0 但 outputs 不存在
- outputs 為空
- validator 不通過
- timeout / stall / hard_fail

## 建議的編譯原則

### 原則 1：summary-first

先用最少 capability 找到任務方向，再決定是否展開詳細規格。

### 原則 2：expand-on-demand

只有在任務憲法、上游產物或使用者明確要求時，才展開較重的 step。

### 原則 3：validated-unlocks-downstream

只有 `validated` step 才能滿足 `needs`。

### 原則 4：degraded is visible

fallback / unresolved / manual decision 都要明確留痕，不可默默降級。

## 以小工具任務為例

使用者輸入：

> 用 Tauri 做個 AI 額度監控小工具

不應直接展開成完整 delivery workflow。

比較合理的流程：

1. 反問：
   - 是否真的要 UI？
   - 是否只做規劃？
   - 是否允許先做 discovery？

2. 產出 task constitution：
   - 目標：個人小工具
   - 非目標：不上線、不做正式交付
   - 限制：Rust/Tauri 為未知領域
   - 停止條件：缺 Rust 能力時先停在規劃

3. 推導 capability graph：
   - `prd_generation`
   - `technical_planning`
   - `business_analysis?`
   - `database_api_design?`
   - `ui_design?`

4. 編譯結果可能只剩：
   - `prd`
   - `tech_plan`

而不是完整 7~14 步規格鏈。

## 與固定 workflow 的關係

這不是要刪掉固定 workflow。

固定 workflow 仍然適合：

- 團隊已知流程
- 高重複性工作
- 已有穩定 skill 組合

task-scoped compiler 適合：

- 新需求
- 不確定是否需要完整流程
- skill availability 變動
- 先規劃再決定要不要展開

最終應該是雙軌：

- **template workflow**：固定流程
- **compiled workflow**：依任務動態生成最小流程

## 建議落地順序

1. 先定義 `task constitution` schema
2. 再定義 `step state / blocked reason / exit policy`
3. 再把 executor 升級成 artifact-aware gate executor
4. 最後才做 capability graph builder 與 workflow compiler

## 目前不做的事

這份草案目前不直接處理：

- LangGraph backend
- agent 自動生成器
- 自動學習新 workflow 模板
- 完整 GUI 編排介面

這些都應該排在 runtime state / artifact gate 之後。
