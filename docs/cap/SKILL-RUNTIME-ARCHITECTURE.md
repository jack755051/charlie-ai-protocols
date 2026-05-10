# Skill Runtime Architecture

> 本文件描述 CAP 的 capability → skill 綁定模型與 runtime 行為，並標註仍在 draft 的下一階段擴充。
> workflow 治理層的整體 roadmap 以 [IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md) 為主；本文件聚焦於 skill registry、RuntimeBinder 與 fallback 行為。

## 狀態標記

- **正式 runtime（已實作並 ship）**
  - `engine/runtime_binder.py` — capability → skill 綁定核心
  - `.cap.skills.yaml` — workflow binding 的優先輸入
  - `schemas/skill-registry.schema.yaml`（v2，已合併原 skill-manifest 欄位）
  - `cap workflow plan` / `bind` / `run`
  - `scripts/cap-workflow-exec.sh` 消費 bound execution plan
- **正式相容層**
  - `.cap.agents.json`（legacy adapter）
  - `engine/workflow_loader.py::build_execution_phases()`（legacy loader，仍供舊路徑使用）
- **仍在 draft（尚未實作，見 §「Draft 範圍」與 §「演進方向」）**
  - 遠端 marketplace 拉取 / 安裝 / 升級
  - LangGraph backend 實作
  - 統一 State Container
  - Checkpoint / 可恢復執行
- **v0.19.x 已部分實作**
  - dispatch 前自動 materialize handoff ticket — 透過 `scripts/workflows/emit-handoff-ticket.sh` 與三條 per-stage workflow 中 `emit_<step>_ticket` 顯式 shell step 達成；engine `step_runtime` 自動 hook（不需要在 workflow YAML 顯式插步驟）仍在 deferred 範圍

## 核心原則

- **workflow 只描述流程語意**：`step`、`needs`、`gate`、`fail route`、`governance`
- **capability 是流程與實作之間的穩定介面**
- **agent-skill 是可插拔實作，不是 workflow 的直接依賴**

一句話：

- `workflow` 是地圖
- `capability` 是職缺
- `agent-skill` 是可替換的人員

## 為什麼分兩階段（build vs bind）

早期 runtime 偏向早綁定：在建 plan 時就把 capability 直接解析成固定 agent。這對固定團隊有效，但對「skill 可被第三方匯入 / 匯出」的場景會撞牆：

1. 缺 skill 會導致 workflow 無法完整建 plan
2. registry 的 skill 變動會直接影響 workflow 可讀性與可審核性

`cap workflow plan / bind / run` 已改為共用 `RuntimeBinder`，把流程建構與 skill 綁定拆成兩階段；舊版 `build_execution_phases()` 只保留為相容 loader，不再是 workflow CLI 的主要路徑。

## 執行模型（現況）

### 1. Build

- 只讀取 workflow 與 capability contract
- 驗證 phase / gate / governance 是否合理
- **不要求 skill 一定存在**

輸出：`semantic plan`

### 2. Bind / Preflight

- 依 skill registry 將 capability 綁到可用 skill
- **Phase 5+（v0.25.0+）：capability 同時綁兩個 slot — `selected_role`（executor）與 `attached_skills[]`（advisory guardrails）**
  - `selected_role`：`_find_candidates` 只挑 `kind=role` 的條目作為 executor。`kind=skill` 條目永遠不會單獨被選為 executor。
  - `attached_skills[]`：`_find_attached_skills` 嚴格 opt-in，只附掛宣告了 `attach_to_capabilities` / `attach_to_roles` 的 `kind=skill` 條目。**沒有 auto-fan-in**（同 capability 內任意 skill 都自動掛上會讓附掛行為不可審計，已在 ADR-style note 內否決）。
  - role + attachments 的 source policy 各別過閘門（`_assert_skill_source_allowed`），任一不在 `effective_allowed_roots` 內就 halt 整個 binding，不會悄悄 drop attachment。
- 若找不到 skill，標記為：
  - `required_unresolved`
  - `optional_unresolved`
  - `fallback_available`
- 依 binding policy 決定是否：
  - `halt`
  - `substitute`
  - `manual`

輸出：`binding report`，含 `selected_role` 物件 + `attached_skills[]` 陣列（v0.25.0+ schema 增量欄位，向下相容；舊 report 仍可驗）。

```text
capability
  ├─ selected_role         (kind=role; 執行 step、擁有 task identity)
  │    ↳ prompt_file       (cap-workflow-exec.sh build_step_prompt 第一段渲染)
  └─ attached_skills[]     (kind=skill; advisory guardrail / checklist)
       ├─ attach_reason: attach_to_capabilities | attach_to_roles
       └─ prompt_file      (build_step_prompt 第二段「附加規範指引」渲染)
```

### 3. Execute

- 只有在 preflight 可接受時才進入正式執行
- handoff / governance / watcher / logger 仍由 CAP 自己的 schema 管理
- AI step prompt 組裝順序（Phase 5+）：
  1. role prompt 路徑（「請嚴格依照 ${SKILLS_DIR}/${prompt_file}」）
  2. 「附加規範指引 (Attached Advisory Skills)」區塊，列出 `attached_skills[]` 中每條的 `prompt_file`（含 `skill_id` 與 `attach_reason` 供 audit）
  3. structured sections（contract / handoff template）
- shell-executor step 不會走到 `build_step_prompt`，因此 `attached_skills` 對 shell step 是 no-op（binding report 仍會寫入空陣列以保持 shape 一致）。

## 設計結論

未來若 skill 缺失：

- **workflow 應該仍可載入、展示、審核**
- 只有 execution plan 進入 `degraded` 或 `blocked`
- 不應因為 marketplace 缺 skill 就讓 workflow 壞掉

## 與 LangChain / LangGraph 的關係

### 架構比對

| 特性 | LangChain | LangGraph | CAP workflow |
|---|---|---|---|
| **執行模型** | 線性 Chain / Sequential | 有向圖 (DAG + 可循環) | DAG（`needs` 拓撲排序 + `_compute_phases`） |
| **平行執行** | 不原生支援 | 支援（分支節點） | 支援（`parallel_with` + 同 phase 並行） |
| **條件路由** | Router Chain，較笨重 | 原生 conditional edges | `on_fail_route` 條件分流（SRE_TRIGGER / LH_*_FAIL 等） |
| **循環 / 回流** | 無 | 原生支援 cycle | 有概念（`route_back_to`、gate fail → reroute），executor 尚未自動重跑修復後 gate |
| **狀態管理** | Chain 內隱式傳遞 | 顯式 `TypedDict` State + reducer | artifact 導向（`inputs/outputs` + `artifact_manifest`），無統一 runtime state container |
| **Checkpoint** | 無 | 內建 checkpointer，可中斷恢復 | 無；phase 一次性跑完，中斷後無法從中間恢復 |
| **Human-in-the-loop** | 靠外部邏輯 | 原生 `interrupt_before/after` | 有（PRD 使用者確認、gate 失敗 Supervisor 裁決），但靠 prompt 約定，非 runtime 機制 |
| **治理 / 監管** | 無 | 無內建 | CAP 獨有（`governance`、watcher/logger checkpoint、handoff validation） |

### 定位結論

- CAP 的 workflow 系統**已不是 LangChain 架構**，而是介於 LangGraph 和自建 orchestrator 之間
- `LangChain` 不適合直接取代 CAP 的 workflow 治理模型
- `LangGraph` 可以作為 runtime backend
- **workflow / capability / handoff / governance 仍應由 CAP 自己維持 SSOT**

職責切分：

- CAP schema 負責規則與治理（workflow、capability、handoff、governance）
- LangGraph 可負責圖執行、狀態流轉、節點呼叫與回圈控制
- LangGraph 不應取代 workflow schema 本身

### CAP 已具備的 LangGraph 等價能力

| LangGraph 概念 | CAP 對應實作 |
|---|---|
| Graph nodes + edges | `steps` + `needs` 拓撲排序 |
| Conditional edges | `on_fail_route`（QA → SRE / Troubleshoot / Frontend） |
| Parallel branches | `parallel_with` + phase 並行排程 |
| Interrupt / human-in-the-loop | `gate`（`all_pass`）、PRD 使用者確認 |
| Standby nodes | `standby_steps`（troubleshoot / sre 條件觸發） |

### CAP 超越 LangGraph 的差異化優勢

LangGraph 生態目前**完全不具備**以下能力：

1. **Governance 層**：`watcher_mode` / `logger_mode` / `checkpoint` — 橫向監管軌可在關鍵里程碑強制介入稽核與留痕
2. **Capability-first binding**：workflow 綁 capability 而非 agent — skill 可插拔替換，workflow 不因 agent 變動而失效
3. **Handoff ticket validation**：`validate_handoff_ticket()` 防止 dispatch 覆寫 workflow 的 step / capability / phase / checkpoint 約束
4. **Preflight degradation**：binding 報告區分 `ready` / `degraded` / `blocked`，workflow 在 skill 缺失時仍可載入審核

### 演進方向：補強兩項 LangGraph 原生能力

CAP 目前與 LangGraph 的主要差距在兩處，可借鑑其概念補強：

#### 1. 統一 State Container

- **現狀**：artifact 用 `inputs/outputs` 字串清單描述，無 runtime 級 shared state
- **目標**：在 `build_bound_execution_phases()` 結果中加入 `state: dict`，executor 在每個 step 完成後寫入 artifact 路徑與 gate 結果，下游 step 從 state 讀取
- **效益**：消除 step 間靠隱式檔案路徑傳遞的脆弱性

#### 2. Checkpoint / 可恢復執行

- **現狀**：`cap workflow run` 中斷後無法從已完成的 phase 繼續
- **目標**：每個 phase 完成後將 state 序列化到 `~/.cap/projects/<id>/checkpoints/`，恢復時從最後 checkpoint 繼續
- **效益**：較長的多階段 workflow 不再因中途斷線而全部重來

> 這兩項加上後，CAP 即為「帶 governance 的 LangGraph」。governance 層是目前 LangGraph 生態沒有的差異化優勢，應持續由 CAP schema 維持 SSOT。

## 本 repo 內的 SSOT 檔案

- `.cap.skills.yaml` — 實際 skill registry（與 `.cap.skills.example.yaml` 內容已同步，後者僅作為新 repo 安裝範本）
- `schemas/skill-registry.schema.yaml`（v2，含原 manifest 欄位）
- `engine/runtime_binder.py`（binding report 結構已內化為 docstring）

## 本地試跑方式

1. 複製範例 registry：

```bash
cp .cap.skills.example.yaml .cap.skills.yaml
```

2. 查看 workflow 的 semantic + binding 狀態：

```bash
cap workflow plan version-control
cap workflow bind version-control
```

> 補充：若 `.cap.skills.yaml` 不存在，runtime binder 會自動把 `.cap.agents.json` 轉成 legacy adapter，讓 `plan / bind / run` 仍可維持 `ready / degraded / blocked` 判定。

## Draft 範圍

目前已做到：

- workflow semantic plan 與 skill binding 分離
- skill registry 可缺省
- capability 缺 skill 時輸出 `unresolved binding report`
- `cap workflow run` 會先做 preflight：`blocked` 停止，`degraded` 明確提示
- executor 消費 bound execution plan，並可使用 skill registry 指定的 per-step `cli`

本草案**尚未**做到：

- marketplace 遠端拉取
- 真正的 registry 安裝 / 升級 CLI
- dispatch 前自動 materialize handoff ticket
- LangGraph backend 實作
- `.cap.skills.yaml` schema 的穩定版與遷移工具
