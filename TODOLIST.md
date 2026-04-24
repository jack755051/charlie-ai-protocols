# Workflow Design TODO List

更新日期：2026-04-24

## 目標

把固定流程抽象成可重複使用的 workflow（`schemas/workflows/`），同時保留 agent 可替換性，避免把流程順序硬編碼進 `docs/agent-skills/*.md`。

## 開發備忘

### 已確認的分層原則

- `CAP` 應定位為平台層，負責 runtime、binding、compile、promote 與 registry adapter，不應兼任正式 skill 內容倉庫。
- `agent-skill` 是能力與邊界的基底；`workflow` 是依需求組裝 capability 的編排層。
- `.cap` / `~/.cap/projects/<project_id>/` 只保存 runtime artifact，例如 compiled workflows、bindings、traces、logs、sessions、handoffs、reports。
- 其他專案產出的正式 skill / workflow，不應預設保存到 `.cap`；應保留在該專案 repo 內，接受版本控制與審查。
- 專案層應保留自己的正式宣告位置，例如 `.cap.constitution.yaml`、`.cap.skills.yaml`、`workflows/`、`docs/workflows/` 或 `schemas/workflows/`。
- runtime 只負責解析 repo 內宣告並產生 snapshot，不應反過來讓 `.cap` 成為正式來源。
- 若有跨專案共用 skill，應走 shared registry / 平台內建資產，而不是依附在某單一專案的 `.cap`。

### 多 repo 模型

- 當使用者同時管理 `A/B/C/D/E` 多個 repo 時，應視每個 repo 為獨立 project，而不是共用同一份專案 skill / workflow 原文。
- `CAP` 可內建一套平台級 baseline：
  - base agent-skills
  - base workflows
  - base capability contracts
  - base governance / binding / compile / promote 機制
- 每個 repo 在產生客製 skill / workflow 之前，應先有自己的 `Project Constitution`，用來描述該 repo 的治理原則、限制、交付偏好與允許的能力範圍。
- 先產生 `Project Constitution`，再根據它產生該 repo 的 skill / workflow，這個方向合理；真正要避免的是把正式來源與 runtime workspace 混在一起。
- 建議採四層模型：
  - Platform Constitution：CAP 平台自身的全域原則與內建基底
  - Project Constitution：各 repo 自己的憲法與治理規則
  - Project Source Assets：各 repo 正式保存的 skills / workflows / bindings
  - Runtime Workspace：執行時寫入 `~/.cap/projects/<project_id>/` 的快照、編譯結果與過程資料
- 核心鐵則：
  - repo 放 source of truth
  - `.cap` 放 runtime state
  - snapshot 可以進 `.cap`
  - 正式原文不要只留在 `.cap`

### 已完成事項

- [x] 定義 workflow 與 agent 的分層原則
  - `agent-skills/` 只描述角色能力與邊界
  - `schemas/workflows/` 只描述步驟、依賴、條件與產物
  - runtime 負責把 workflow step 綁定到實際 agent

- [x] 新增 workflow 規格目錄
  - 建立 `docs/workflows/README.md`
  - 建立 `docs/workflows/workflow-schema.md`
  - 明確定義 `workflow_id`、`version`、`steps`、`capability`、`needs`、`outputs`、`optional`

- [x] 設計 capability contract
  - 為常用能力定義 `inputs`
  - 定義 `outputs`
  - 定義 `done_when`
  - 定義 `handoff_schema`
  - 已落地為 `schemas/capabilities.yaml` 與 `schemas/handoff-ticket.schema.yaml`

- [x] 建立 capability 到 agent 的綁定表
  - 例如 `readme_normalization -> 101-readme-agent`
  - 例如 `devops_delivery -> 06-devops-agent`
  - 支援 `default_agent` 與 `allowed_agents`

- [x] 撰寫第一個 workflow 範例
  - `docs/workflows/readme-to-devops.yaml`
  - 以 capability slot 描述，不直接綁死 agent 檔名

- [x] 決定 workflow artifacts 的正式落點
  - repo 內 workflow 定義放 `schemas/workflows/`
  - capability contract 放 `schemas/capabilities.yaml`
  - handoff schema 放 `schemas/handoff-ticket.schema.yaml`
  - 執行期草稿與報告放 `~/.cap/projects/<project_id>/`
  - legacy 筆記暫放 `workspace/history/`

- [x] 暫不引入 LangChain
  - 先完成 workflow spec
  - 先用現有 `CrewAI + 自家 orchestration` 驗證
  - 只有在 graph、checkpoint、stateful branching 明顯變複雜時再評估 `LangGraph`

- [x] 建立 repo 級正式來源入口
  - 新增 `.cap.project.yaml` 欄位：`project_type`、`constitution_file`、`skill_registry`、`workflow_dir`
  - 新增 `.cap.constitution.yaml` 作為 repo 級 `Project Constitution`
  - 新增 `.cap.skills.yaml` 作為 repo 級正式 skill registry
  - 更新 `README.md` 與 `repo.manifest.yaml` 反映四層模型

- [x] 讓 engine 可讀取 repo 級 `Project Constitution`
  - 新增 `engine/project_context_loader.py`
  - `task constitution` 會帶出 `project_context`
  - `binding report` 會帶出 `project_context`
  - constitution / compile / binding report 已可顯示 `project_constitution_path`

- [x] 讓 `Project Constitution` 開始實際生效
  - `binding_policy.defaults` 可覆寫 runtime binding 預設值
  - `binding_policy.allowed_capabilities` 可限制 capability 範圍
  - `workflow_policy.allowed_source_roots` 可限制 workflow 來源目錄
  - 不允許的 capability 目前會標記為 `blocked_by_constitution`

## 後續 5 步驟

1. 建立 project initializer
   - 提供 A/B/C/D/E 任一 repo 一鍵生成 `.cap.project.yaml`、`.cap.constitution.yaml`、`.cap.skills.yaml`
   - 區分 platform repo 與一般 application repo 的初始化模板

2. 定義 `Project Constitution` schema
   - 把目前的 `binding_policy`、`workflow_policy`、source-of-truth 欄位正式 schema 化
   - 補上欄位驗證與向後相容策略

3. 導入 repo-specific workflow/skill 來源解析
   - 讓 runtime 除了吃內建 `schemas/workflows/`，也能安全解析 repo 內 `workflows/` 或 `docs/workflows/`
   - 讓 skill registry 可明確區分 builtin / project / shared 三種來源

4. 建立 promote / publish 流程
   - 把某個 repo 中成熟的 project skill / workflow 升級成 CAP 平台內建資產或 shared registry
   - 避免跨專案複製貼上造成多份漂移版本

5. 補 migration note 與 supervisor/runtime 治理說明
   - 說明舊有 workflow / agent prompt 模式如何遷移到 `Project Constitution -> source assets -> runtime workspace`
   - 補清楚 supervisor、binder、compiler、runtime 各自的責任邊界

## TODO

- [ ] 定義 supervisor 的新責任
  - 讀取 `schemas/workflows/` 中的 workflow 定義
  - 依 capability 尋找對應 agent
  - 檢查 step 產物是否符合 `schemas/capabilities.yaml` 契約
  - 在失敗時 reroute 或要求重工

- [ ] 補一份 migration note
  - 說明目前 `典型交付順序` 與 `schemas/workflows/` workflow definition 的差異
  - 說明 agent prompt 已移除 orchestration logic，只保留 capability、methodology 與 output format
  - 說明 `Project Constitution`、repo 正式來源與 `.cap` runtime workspace 的分工

## 近期建議順序

1. ~~先出 `workflow-schema.md`~~ (done: `docs/workflows/workflow-schema.md`)
2. ~~再出 `readme-to-devops.yaml`~~ (done: `schemas/workflows/readme-to-devops.yaml`)
3. ~~再補 capability registry~~ (done: `schemas/capabilities.yaml`)
4. ~~建立 repo 級 constitution / registry 入口~~ (done: `.cap.constitution.yaml`, `.cap.project.yaml`, `.cap.skills.yaml`)
5. ~~讓 engine 讀取並套用 `Project Constitution`~~ (done: `engine/project_context_loader.py`, `runtime_binder.py`, `task_scoped_compiler.py`)
6. 下一步優先做 project initializer 與 constitution schema
