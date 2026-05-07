# Agent-Skills Customization Guide

> 使用者導向：**如何在不改動 `<cap_root>/agent-skills/` 的前提下**，自訂專案專屬的 agent skill。
> Normative SSOT：[`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md)、[`schemas/skill-registry.schema.yaml`](../../schemas/skill-registry.schema.yaml)。
> 本指南只示範使用情境與範例。

## TL;DR

1. **不要動** `<cap_root>/agent-skills/*.md`：這是 CAP 的 builtin baseline，唯讀。
2. 自訂走專案層 `<project_root>/.cap/skills.yaml`。
3. 三種 customization 模式：直接 override（同 skill_id）、disable（tombstone mask）、replace（用新 id 取代）。

## 場景 1：覆蓋官方 skill（最常見）

需求：把 builtin frontend 換成自家 React 18 專屬版本，仍綁同一 capability。

```yaml
# <project_root>/.cap/skills.yaml
schema_version: 1

skills:
  - skill_id: builtin-frontend       # 與官方同 id
    agent_alias: frontend
    provider: builtin
    enabled: true
    priority: 100
    prompt_file: agent-skills/frontend-react18.md   # 你自己的 prompt
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
    fallback_roles:
      - implementer
```

效果：`RuntimeBinder` 合併 layer 時 project 層 first-seen 進結果，builtin 層同 id 條目被丟棄。Binding report 會顯示 `skill_source.source_layer = project`。

## 場景 2：停用某個官方 skill（不想自己寫替代）

需求：本專案沒有 Figma 流程，要關掉 builtin Figma sync skill；workflow 解到該 capability 時走 unresolved 而非預設 builtin。

```yaml
# <project_root>/.cap/skills.yaml
schema_version: 1

skills:
  - skill_id: builtin-figma
    disabled: true
```

效果：

- builtin 層的 `builtin-figma` 被 mask；`figma_sync` capability 的 binding 走 unresolved（required → halt；optional → skip）。
- 該 skill 在 binding report 仍可見（`skill_source` 帶 `mask_reason: disabled`），稽核可追蹤。
- 即使有 generic fallback skill 也**不會**被選中（防止 mask 行為被 fallback 繞過）。

## 場景 3：用新 skill_id 取代官方 skill（保留命名語意）

需求：要明確標示「這是 my-frontend-react18，取代了 builtin-frontend」，又想複用官方 capability 列表。

```yaml
# <project_root>/.cap/skills.yaml
schema_version: 1

skills:
  - skill_id: my-frontend-react18
    replaces: builtin-frontend
    agent_alias: frontend
    provider: builtin
    enabled: true
    priority: 110
    prompt_file: agent-skills/frontend-react18.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    # provided_capabilities 故意不填 → 自動繼承 builtin-frontend 的 capabilities
    fallback_roles:
      - implementer
```

效果：

- `my-frontend-react18` 進 candidate pool，`provided_capabilities` 自動帶 `[frontend_implementation]`（從 builtin-frontend 繼承）。
- `builtin-frontend` 被自動 mask（`mask_reason: replaced_by=my-frontend-react18`），不再參與 candidate 競爭。
- Binding report：`selected_skill_id = my-frontend-react18`、`skill_source.source_layer = project`。

如果 replacement **自己填了** `provided_capabilities`，以 replacement 為準，不繼承（適用於「我要重新定義這個 skill 的 capability scope」的情境）。

## 場景 4：跨專案共享自訂 skill（shared layer）

需求：個人本機所有 repo 都要套用同一個 lighthouse audit skill，但不想進每個專案的 git。

1. 寫到 shared 層：
   ```yaml
   # ~/.cap/shared/skills.yaml
   skills:
     - skill_id: my-shared-lh-auditor
       agent_alias: qa
       provider: builtin
       enabled: true
       priority: 90
       prompt_file: ~/.cap/shared/prompts/lh-auditor.md
       cli: claude
       compatible_workflow_versions: [1, 2, 3]
       provided_capabilities:
         - qa_testing
       fallback_roles:
         - reviewer
   ```

2. **在每個專案的 `.cap/constitution.yaml`** 顯式宣告 shared 路徑為 allowed source root：
   ```yaml
   workflow_policy:
     enforce_allowed_source_roots: true
     allowed_source_roots:
       - ~/.cap/shared/skills.yaml
   ```

> Shared layer **預設不被允許**（見 `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` §3.1.2）；不顯式宣告會被 source policy 擋。

## Pitfall 與常見錯誤

- ❌ **直接編輯 `<cap_root>/agent-skills/04-frontend-agent.md`**：違反 baseline 唯讀規則；下次 CAP release 會 conflict。改走 §1 / §2 / §3。
- ❌ **改 `<cap_root>/.cap/skills.yaml`**：那是 builtin 的 registry，會在 `cap pull` / `git pull` 後被覆蓋。
- ❌ **同時對同一 skill 寫 `disabled: true` 與 `replaces`**：會被當成 disabled 處理；想取代就只寫 replaces，想關掉就只寫 disabled。
- ❌ **多個 skill 同時 `replaces` 同一個 builtin**：runtime 會 halt with `OverrideContractError`，需自己留一個。
- ⚠️ **`replaces` 指向不存在的 skill_id**：runtime warn 但不擋（被 replaces 的目標可能來自尚未安裝的 marketplace skill）。

## 驗證自訂結果

跑 `cap workflow bind <workflow-id>`，binding report 會顯示每個 step 實際選中的 skill 與來源：

```bash
cap workflow bind project-spec-pipeline | jq '.steps[] | {step_id, selected_skill_id, skill_source}'
```

預期看到：

```json
{
  "step_id": "draft_frontend_impl",
  "selected_skill_id": "my-frontend-react18",
  "skill_source": {
    "source_layer": "project",
    "source_path": "/Users/.../.cap/skills.yaml"
  }
}
```

## Baseline 版本快照

每次 run 會在 `agent-sessions.json` envelope 紀錄 `agent_skills_baseline`（cap_version、git_commit、dir_hash、per-file hash）。如要 replay 一個舊 run，可用 baseline hash 判斷是否需要 checkout 對應 cap-protocols commit。詳見 [`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md) §7。

## 相關文件

- [Baseline policy SSOT](../../policies/agent-skills-baseline.md)
- [Skill registry schema](../../schemas/skill-registry.schema.yaml)
- [P9 Source Resolver design memo](P9-SOURCE-RESOLVER-DESIGN.md)
- [Agent registry policy（legacy `.cap.agents.json`）](../../policies/agent-registry.md)
