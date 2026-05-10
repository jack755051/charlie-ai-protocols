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

## 場景 5：使用者自訂全新 role（v0.24.11+）

> 與場景 1-3 的差別：那些是**覆蓋既有 builtin role**；本場景是**新增完全屬於使用者的 role**（如 mobile、api-reviewer、game-designer），CAP builtin 沒有對應條目。
> Normative 規則：[`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md) §3.5。

### 5.1 在專案層註冊新 role（最簡單）

需求：本專案有特殊的 mobile 開發需求，要新增一個 `$mobile` role，只在這個 repo 生效。

```yaml
# <project_root>/.cap/skills.yaml
schema_version: 2

skills:
  - skill_id: project-mobile-agent
    kind: role                      # v0.24.7+ 顯式宣告（非必填但強烈建議）
    agent_alias: mobile
    provider: project
    enabled: true
    priority: 100
    prompt_file: agent-skills/mobile-agent.md   # 你自己寫的 prompt
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - mobile_implementation
    fallback_roles:
      - implementer
```

對應的 prompt 檔放在 `<project_root>/agent-skills/mobile-agent.md`（**注意**：這個目錄不會被 `factory.py` glob，必須由 registry entry 顯式引用 `prompt_file` 才會被使用）。

效果：

- workflow 中任何依賴 `mobile_implementation` capability 的 step 會解到 `project-mobile-agent`。
- Binding report：`selected_skill_id: project-mobile-agent`、`skill_source.source_layer: project`。
- 此 role 不影響 builtin frontend / backend / qa 等既有 role。

### 5.2 在 shared 層註冊跨 repo role

需求：你維護的所有 repo 都需要同一個 `$api-reviewer` role 做 API contract review。

**Step 1**：寫到 shared 層

```yaml
# ~/.cap/shared/skills.yaml
schema_version: 2

skills:
  - skill_id: shared-api-reviewer
    kind: role
    agent_alias: api-reviewer
    provider: shared
    enabled: true
    priority: 90
    prompt_file: ~/.cap/shared/prompts/api-reviewer.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - api_contract_review
```

**Step 2**：每個要使用該 role 的專案，在 `.cap/constitution.yaml` 顯式允許 shared root

```yaml
# <project_root>/.cap/constitution.yaml
workflow_policy:
  enforce_allowed_source_roots: true
  allowed_source_roots:
    - ~/.cap/shared/skills.yaml
```

> ⚠️ 不顯式宣告會被 `SkillSourcePolicyError` 擋下（halt binding，不會 silently degrade）。這是設計上故意的 supply-chain 防呆。

### 5.3 驗證新 role 已被 CAP 看到

```bash
cap workflow bind <workflow-id> | jq '.steps[] | {step_id, selected_skill_id, skill_source}'
```

預期：

```json
{
  "step_id": "review_api_contracts",
  "selected_skill_id": "shared-api-reviewer",
  "skill_source": {
    "source_layer": "shared",
    "source_path": "/Users/.../.cap/shared/skills.yaml"
  }
}
```

### 5.4 嚴禁的註冊方式（Hard Rules）

| ❌ 錯誤做法 | 為什麼禁止 |
|---|---|
| 寫入 `~/.codex/AGENTS.md` | Codex CLI 全域檔；非 CAP registry target；CAP runtime 看不到、binding report 無法稽核 |
| 寫入 `~/.claude/CLAUDE.md` | Claude Code 全域檔；同上 |
| 走 `~/.claude/agents/` 註冊 sub-agent | provider 專屬機制；非跨 provider 可移植；CAP runtime 不會解析 |
| 直接編輯 `<cap_root>/agent-skills/*.md` 加新 role | 違反 baseline 唯讀規則；下次 CAP release 會 conflict |
| `provided_capabilities` 與 builtin capability 同名 | 會無意搶 builtin 已綁定的 step；應該用獨立新 capability |

### 5.5 何時應該 promote 成 builtin？

只有當 user role 經過足夠 dogfood（多 provider、多 workflow、多次真實任務驗證確實有用），才考慮提到 CAP builtin baseline。Promotion 流程與證據要求見 `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md` §Phase 6。

## 場景 6：把 advisory skill 附掛到 role（v0.25.0+ kind=skill 嚴格附掛）

> 與場景 1-5 的差別：那些都是「替代或新增 executor role」；本場景是**在不替代 role 的前提下，為 step 額外掛上 guardrail / checklist / strategy 規範**。`kind=skill` 的條目永遠不會單獨成為 executor，只能依使用者宣告的 `attach_to_capabilities` / `attach_to_roles` 附掛到既有 role 上。

### 6.1 嚴格附掛規則（strict-attach）

| 規則 | 說明 |
|---|---|
| `kind: skill` 必填 | 沒有 explicit `kind=skill` 時走 legacy inference（`agent_alias` 缺席→skill）。新寫的 advisory skill 一律建議顯式宣告 `kind: skill`。 |
| 必須有附掛宣告 | 必須 listed 在 `attach_to_capabilities`（推薦，跟 capability 對齊）或 `attach_to_roles`（次要，跟 role 的 `agent_alias` 對齊）。**沒有任何宣告 = 不附掛**（不會做 auto-fan-in）。 |
| 兩個都中時優先順序 | `attach_to_capabilities` > `attach_to_roles`（capability 是 workflow 對外契約，優先）。 |
| 來源政策一致 | 與 role 走相同的 `_assert_skill_source_allowed` 閘門：shared layer 的 advisory skill 必須在 `allowed_source_roots` 顯式授權，否則 binding 會 halt（`SkillSourcePolicyError purpose=attached_skill`）。 |

### 6.2 在 shared 層註冊 advisory skill（最常見）

```yaml
# ~/.cap/shared/skills.yaml
schema_version: 2

skills:
  - skill_id: shared-karpathy-guidelines
    kind: skill
    agent_alias: karpathy-guidelines   # 仍保留為 audit / 名稱用，不會單獨 executor
    provider: shared
    enabled: true
    priority: 80
    prompt_file: agent-skills/strategies/karpathy-guidelines.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - engineering_guardrails
    attach_to_capabilities:        # 嚴格附掛宣告（推薦）
      - frontend_implementation
      - backend_implementation
    # 或 attach_to_roles: [frontend, backend]
```

效果：

- 任何 step 的 capability 是 `frontend_implementation` / `backend_implementation` 時，binding report 會在該 step 的 `attached_skills` 內加入這條記錄，`attach_reason: attach_to_capabilities`。
- step prompt 在原 role prompt 後追加「附加規範指引 (Attached Advisory Skills)」區塊，列出 advisory prompt 路徑供 AI provider 一併讀取。
- `selected_role` / `selected_skill_id` 仍是該 step 真正的 executor role；advisory skill 不會搶走 task identity。

### 6.3 把 advisory skill 限縮到特定 role（attach_to_roles）

當 advisory skill 不適合所有同 capability 的 step、只想附給特定 role 時，使用 `attach_to_roles`：

```yaml
skills:
  - skill_id: shared-react18-checklist
    kind: skill
    provider: shared
    prompt_file: skills/react18-checklist.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    attach_to_roles:
      - frontend       # 只在 selected_role.agent_alias = frontend 時附掛
```

### 6.4 必要的 constitution 授權（shared layer）

shared layer 的 advisory skill 預設不在 implicit allowed roots 內。若你的 project constitution 開啟了 `enforce_allowed_source_roots=true`，必須在 `workflow_policy.allowed_source_roots` 顯式授權 shared registry 路徑：

```yaml
# <project_root>/.cap.constitution.yaml
schema_version: 1
project_id: my-project
binding_policy:
  allowed_capabilities: [...]
workflow_policy:
  enforce_allowed_source_roots: true
  allowed_source_roots:
    - ~/.cap/shared/skills.yaml      # 顯式信任 shared layer
```

未授權時 binding 會 halt：

```text
SkillSourcePolicyError: skill 來源不符合 project constitution 限制:
  step_id=implement purpose=attached_skill skill_id='shared-karpathy-guidelines'
  source_path=/home/u/.cap/shared/skills.yaml
```

### 6.5 驗證 attached skills 是否被掛上

```bash
cap workflow bind project-spec-pipeline | jq '.steps[] | {step_id, selected_role: .selected_role.skill_id, attached: [.attached_skills[].skill_id]}'
```

預期：

```json
{
  "step_id": "implement",
  "selected_role": "builtin-frontend-agent",
  "attached": ["shared-karpathy-guidelines", "shared-react18-checklist"]
}
```

### 6.6 何時用「替代 / 新增 role」 vs 「attach advisory skill」？

| 情境 | 用法 |
|---|---|
| 你想換掉整個 role 的 prompt 內容 | 場景 1（`replaces` / 同 id 覆蓋）或場景 3 |
| 你想新增一個全新領域的 executor | 場景 5（user-imported role） |
| 你想保留官方 role，但**追加**規範或 checklist | 場景 6（advisory skill attach） |
| 你只想關掉某個 capability 的處理 | 場景 2（`disabled: true`） |

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
