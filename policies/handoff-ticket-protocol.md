# Handoff Ticket Protocol (v1)

> 本文件定義 cap 系統中所有 sub-agent 讀取 Type C handoff ticket 與寫出 Type D handoff summary 的通用協議。
> 本協議搭配以下檔案使用：
>   - `schemas/handoff-ticket.schema.yaml`（Type C ticket 結構契約）
>   - `agent-skills/01-supervisor-agent.md` §3.6（supervisor 端的 ticket 發行協議）
>   - `policies/constitution-driven-execution.md` §1.3（Mode C conductor 綁定）

## 1. 適用對象 (Applies To)

凡 cap 系統內被 supervisor 派工的任何 sub-agent，包括但不限於：

- `02-TechLead`, `02a-BA`, `02b-DBA`
- `03-UI`, `04-Frontend`, `05-Backend`, `06-DevOps`
- `07-QA`, `08-Security`, `09-Analytics`, `10-Troubleshoot`, `11-SRE`, `12-Figma`
- `90-Watcher`, `99-Logger`, `101-README`

`01-Supervisor` 自身不在本協議的「讀者」範圍 —— supervisor 是 ticket 的**發行者**，相關規則見 `01-supervisor-agent.md` §3.6。

## 2. 觸發條件 (When To Apply)

在以下情境，sub-agent **必須**讀取 ticket：

1. 從 cap workflow runtime（`step_runtime.py`）被 spawn，且環境變數含 `CAP_HANDOFF_TICKET_PATH`
2. 從 supervisor ad-hoc 派工，且 prompt 中明確指出「請從 `~/.cap/projects/<id>/handoffs/<step_id>.ticket.json` 讀取你的工作單」
3. 路徑 `~/.cap/projects/<project_id>/handoffs/<step_id>.ticket.json` 存在且 `<step_id>` 與你被指派的 step 一致

在以下情境，sub-agent **不必**讀 ticket（沿用既有 prompt 行為即可）：

1. 不在 workflow / cap-spawn 模式（純對話式）
2. 路徑不存在（fallback 到 prompt 內提供的指示）
3. 明確被告知「本次不走 ticket 模式」

## 3. 讀取流程 (Read Flow)

接到派工後：

1. **定位 ticket**：
   - 優先讀 `CAP_HANDOFF_TICKET_PATH`（若有）
   - 否則組路徑 `~/.cap/projects/<project_id>/handoffs/<step_id>.ticket.json`
   - 同 step 重跑時可能存在多份（`<step_id>.ticket.json`、`<step_id>-2.ticket.json` ...），預設讀**最新 seq**

2. **驗證 ticket**：
   - 確認 `target_capability` 確實是你的 capability
   - 確認 `step_id` 與你被指派的 step 一致
   - 若不一致，**halt 並回報錯派工**，不要硬幹

3. **載入規則**：依 `rules_to_load`：
   - `agent_skill`：你的主要角色 skill（最重要，本協議不覆蓋此）
   - `core_protocol`：載入 `agent-skills/00-core-protocol.md`
   - `strategies` / `policies`：依需要載入

4. **解析 context_payload**：
   - `project_constitution_path`：必讀，作為 scope 邊界
   - `task_constitution_path`：必讀，了解整體 task 目標與 stop_conditions
   - `upstream_handoff_summaries`：summary-first 上游摘要清單（≤500 字 excerpt 即夠）
   - `upstream_full_artifacts`：**只在 audit 類 step 才載入全文**；其他情境忽略
   - `inherited_constraints` / `inherited_stop_conditions`：你必須遵守

5. **吸收 acceptance_criteria**：
   - 這是 done_when 的精確版；你結束前必須逐條對照
   - 若任一條無法達成，halt 並回報，不假裝完成

6. **記住 output_expectations**：
   - `primary_artifacts`：你**必須**在指定路徑產出對應檔案
   - `handoff_summary_path`：你**必須**在此路徑寫 Type D 摘要

7. **理解 failure_routing**：
   - `on_fail` 告訴你失敗時 supervisor 期望的回流方式（halt / route_back_to / retry / escalate_user）
   - 你不需要自行決定回流目標；只需確實回報失敗即可

## 4. 產出協議 (Output Flow)

完成 step 後：

1. **寫主 artifact** 到 `output_expectations.primary_artifacts[].path` 指定的路徑
2. **寫 Type D handoff summary** 到 `output_expectations.handoff_summary_path`，格式必須包含：
   - YAML frontmatter（`agent_id` / `step_id` / `task_id` / `result` / `output_paths`）
   - `task_summary`：一句話
   - `key_decisions`：關鍵決策清單
   - `downstream_notes`：下游應注意事項
   - `risks_carried_forward`：未解決的風險
   - `halt_signals_raised`：halt 訊號（如有）
3. **不要寫 ticket 檔本身**（那是 supervisor / shell 寫的，不是你寫的）
4. **不要動其他 step 的 ticket**（即使你 audit 類 step 看到別的 ticket，只讀不改）

## 5. 失敗與 halt 協議 (Failure Handling)

- 若 acceptance_criteria 任一條無法達成 → 寫 Type D 標 `result: 失敗` 並具體說明哪條 fail，halt 不偽造完成
- 若 ticket 本身結構錯誤（必填欄位缺失） → halt 並回報「ticket 結構錯誤」，不嘗試修補 ticket
- 若 stop_condition 觸發 → 寫 Type D 標 `halt_signals_raised`，halt 並回報，由 supervisor 決定後續
- 若你發現 task constitution 與 ticket 衝突（如 acceptance_criteria 與 task 整體 success_criteria 矛盾） → halt 並回報，不擅自選一份硬做

## 6. 與既有 agent skill 的關係

本協議不取代任何 agent skill 的 core mission；它只規範**派工協議的形狀**。具體業務邏輯仍由各 agent skill 定義：
- TechLead 仍依 `02-techlead-agent.md` 產 TechPlan
- BA 仍依 `02a-ba-agent.md` 產 BA spec
- Watcher 仍依 `90-watcher-agent.md` 做稽核

ticket 提供的是**統一的派工載體**，讓這些 skill 在 cap workflow 與跨 runtime 場景下能被一致地呼叫，而不影響各自的職責邊界。

## 7. 違規訊號

- 不讀 ticket 卻自行決定 step 範圍 / acceptance_criteria
- 把上游 full_artifacts 全載入卻沒有 audit 類 step 授權
- 修改別人的 ticket 或 task constitution
- ticket 與 prompt 衝突時擅自選一份做（應 halt 並回報）
- handoff summary 沒寫到 ticket 指定路徑
- handoff summary 缺少 YAML frontmatter 或核心欄位

## 8. 版本歷程

- v1（本檔）：初版。定義適用對象、觸發條件、讀取與產出流程、失敗協議。後續若 ticket schema 升版，本協議須同步調整。
