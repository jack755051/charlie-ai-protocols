# CAP Agent-Skills Baseline Policy (v1)

> 本文件定義 `agent-skills/` 在 CAP 平台中的角色、寫入權與自訂路徑。
> SSOT：`policies/agent-skills-baseline.md`（本檔）。
> 上層引用：`agent-skills/00-core-protocol.md` §3 Protocol Source Read-Only、`policies/agent-registry.md` §5。

## 1. 定位（What `agent-skills/` Is）

`agent-skills/` 是 CAP 的**官方 agent-skill baseline**：

- **唯讀基底**：對使用者專案而言，這個目錄是不可變的官方規則來源。
- **由 CAP release 維護**：欄位更動、語意調整、刪除合併，**只能**透過 CAP repo (`charlie-ai-protocols`) 的正式 release 流程進行。
- **三消費者共用**：CrewAI `factory.py`、Claude Code `@` 引用、Codex `$skill` 映射全部讀同一份 SSOT；不允許任何消費者建立自己的局部副本（symlink fan-out 例外，由 `scripts/mapper.sh` 控管）。
- **與其他 SSOT 對稱**：與 `policies/`、`schemas/`、`engine/` 同屬 protocol source；唯讀規則由 `agent-skills/00-core-protocol.md` §3 統一聲明。

## 2. 寫入權（Who May Write）

| 角色 | 是否可改 `agent-skills/*.md` | 路徑 |
|---|---|---|
| CAP 維護者（release pipeline） | ✓ | `charlie-ai-protocols` repo `master` 分支，需走 commit + tag |
| Runtime（執行期） | ✗ | runtime 嚴禁反向修改任何 `agent-skills/` 檔；違反屬重大事故 |
| 使用者專案 | ✗ | 不得直接編輯；自訂走 §3 三層 layer |
| AI agent / sub-agent | ✗ | 與使用者同層；以 `@` 引用後**只讀** |

## 3. 自訂路徑（How to Customize）

CAP 的 source resolver 已實作 `project > shared > builtin` 三層覆蓋（見 `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` §3 / §5）：

| Layer | Skill registry 路徑 | 寫入者 | 進 git？ | 預設 allowed |
|---|---|---|---|---|
| `project` | `<project_root>/.cap/skills.yaml` 或 `<project_root>/.cap/skills/*.{yaml,yml,json}` | 使用者 | 進專案 git | ✓ |
| `shared` | `<cap_home>/shared/skills.yaml` 或 `<cap_home>/shared/skills/*.{yaml,yml,json}` | 使用者本機 | 不進 git | ✗（須在 constitution 顯式宣告） |
| `builtin` | `<cap_root>/.cap/skills.yaml`（即本 repo） | CAP release | 進 cap-protocols git | ✓ |

合併規則（`engine/runtime_binder.py:_merge_skill_layers`）：

- **同 `skill_id`**：高層 wins（first-seen 進合併結果）。
- **`disabled: true`**（v0.22.0+）：高層可遮蔽低層的同 `skill_id`，行為類似 tombstone（詳見 §4）。
- **`replaces: <skill_id>`**（v0.22.0+）：高層 skill 取代低層另一 `skill_id`，被取代者一併 mask（詳見 §4）。

## 3.5 User-Imported New Role (v0.24.11+)

> 範圍：使用者**新增**自己的 agent role（如 `mobile`、`api-reviewer`），而非覆蓋 builtin。covers Phase 3 of `docs/cap/ROLE-SKILL-REGISTRY-MODEL-MEMO.md`。
> 完整 how-to 與範例：[`docs/cap/AGENT-SKILLS-CUSTOMIZATION.md`](../docs/cap/AGENT-SKILLS-CUSTOMIZATION.md) 場景 5。

### 3.5.1 Registry contract

使用者註冊新 role 必須走 project / shared layer，**不得**改 builtin。entry 欄位最低要求：

| 欄位 | 規則 |
|---|---|
| `skill_id` | 不得與 builtin / 既有 layer 衝突；建議前綴 `project-` / `shared-` 表明來源 |
| `kind` | 建議顯式設 `kind: role`（v0.24.7+ enum），方便日後 Phase 5 attachment 區分 |
| `agent_alias` | 必填；對應 prompt 內角色身分，未來作為 `cap agent` alias |
| `prompt_file` | 必填；指向 user-owned prompt 檔（路徑可在 `<project_root>/agent-skills/`、`<cap_home>/shared/prompts/` 或絕對路徑） |
| `cli` | 必填；`claude` / `codex` / 其他 provider |
| `provided_capabilities` | 至少一條；新 capability 不得與 builtin 既有 capability 重名（避免無意搶 builtin） |
| `compatible_workflow_versions` | 建議填具體版本陣列，避免永久全相容造成日後升級偏差 |

註：`agent_alias` + `prompt_file` + `cli` 三件齊備是 `RuntimeBinder._has_execution_metadata` 的選中前提；缺任一者該 entry 仍會載入但**無法被選為 step executor**。

### 3.5.2 Source layer 與 allowed_source_roots

| Layer | 路徑 | 預設 allowed | 額外條件 |
|---|---|---|---|
| `project` | `<project_root>/.cap/skills.yaml`（或 `.cap/skills/<id>.yaml`） | ✓ 自動允許 | 無；project 層 user role 開箱即可被選中 |
| `shared` | `<cap_home>/shared/skills.yaml`（或 `shared/skills/<id>.yaml`） | ✗ 預設**不**允許 | 必須在 project constitution 顯式宣告 `workflow_policy.enforce_allowed_source_roots: true` 且把 shared 路徑加進 `allowed_source_roots` |

> Shared layer 不被預設允許是 P9 source policy 的設計（見 `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` §3.1）。理由：cross-project 共享資源需要每個 repo 顯式同意，否則 supply-chain 風險（任何本機 cap_home 改動即可影響所有 repo）不可控。

未在 `allowed_source_roots` 宣告的 shared-layer source 一旦被選中，runtime 會以 `SkillSourcePolicyError` halt binding（不得 degrade 為 fallback 隱藏越界）。

### 3.5.3 寫入權邊界（Hard Rules）

User-imported role 嚴格走 CAP registry，**禁止**繞過走 provider global file：

- ❌ **不得寫入 `~/.codex/AGENTS.md`**（Codex CLI 全域檔；非 CAP registry target）
- ❌ **不得寫入 `~/.claude/CLAUDE.md`**（Claude Code 全域檔；非 CAP registry target）
- ❌ **不得依賴 provider IDE / CLI 的 sub-agent 機制**註冊 user role（如 `~/.claude/agents/`）；那不是跨 provider 可移植的 registry，CAP runtime 看不到，binding report 也無法稽核
- ✅ **可以**在 `<project_root>/agent-skills/<your-agent>.md` 放自訂 prompt，但僅作為 `prompt_file` 欄位的目標路徑（`factory.py` 不會 glob 它，必須由 registry entry 顯式引用）
- ✅ **可以**在 `<cap_home>/shared/prompts/` 放跨 repo 共享 prompt，前提是該專案 constitution 允許 shared root

### 3.5.4 與 §4 的關係

§4 的 override / disable / replace 契約**也適用**於 user-imported role：兩個 layer 都註冊同 `skill_id` 的 user role 時，project 層 first-seen 勝出；user role 可以被 `disabled: true` 在更高層 mask；user role 可以用 `replaces:` 取代 builtin 或其他 user role。差別僅在「是否覆蓋 builtin baseline」這個語意層面，runtime 合併規則完全一致。

## 4. Override / Disable / Replace 契約

### 4.1 同 `skill_id` 直接覆蓋（最常見）

```yaml
# <project_root>/.cap/skills.yaml
skills:
  - skill_id: builtin-frontend       # 與 builtin 同 id
    agent_alias: frontend
    provider: builtin
    enabled: true
    priority: 100
    prompt_file: agent-skills/frontend-custom.md
    cli: claude
    compatible_workflow_versions: [1, 2, 3]
    provided_capabilities:
      - frontend_implementation
    fallback_roles:
      - implementer
```

效果：runtime 載入時 project 層 `builtin-frontend` first-seen 進合併結果，builtin 層同 id 條目被丟棄。

### 4.2 Tombstone Mask（`disabled: true`）

```yaml
# <project_root>/.cap/skills.yaml
skills:
  - skill_id: builtin-figma
    disabled: true
```

語意（v0.22.0+）：

- 該 `skill_id` 在合併後被標記為 `_masked: true`。
- `_find_candidates` 與 `_find_fallback` **不可選中** masked skill。
- 低層同 `skill_id` 的條目**不可成為 fallback** 取代它（防止 fallback 把 mask 行為繞過）。
- Binding report 仍可見：`steps[*].skill_source` 記錄 masked 來源；診斷 / audit 不受影響。

使用情境：使用者要關掉某個 capability 的 builtin 實作，但又不想自己寫一個取代品（runtime 走 unresolved → halt 或 fallback 角色）。

### 4.3 Replacement（`replaces: <skill_id>`）

```yaml
# <project_root>/.cap/skills.yaml
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
    # provided_capabilities 未填 → 自動繼承 builtin-frontend 的 capabilities
    fallback_roles:
      - implementer
```

語意（v0.22.0+）：

- `replaces: <other_skill_id>` 不需與 replacement 自身的 `skill_id` 相同。
- **被 replaces 的 skill 同步 mask**（避免雙 candidate）。
- **capabilities 繼承規則**：
  - 若 replacement **未填** `provided_capabilities`（缺 key 或為空陣列）→ 自動繼承被 replaces 的 capabilities。
  - 若 replacement **自己填了** `provided_capabilities` → 以 replacement 為準，不繼承。
- Binding report：被 replaces 的 skill_id 出現在 `_masked` 集合，原因標 `replaced_by=<replacement_id>`。

使用情境：使用者要用全新 skill_id 取代官方 baseline，並保留命名語意（如 `my-frontend-react18`）。

### 4.4 不允許的混用

- 同一 skill 既寫 `disabled: true` 又寫 `replaces` → 保守解讀為 mask（disabled 優先），整個條目本身不被選中。
- 多個 skill 同時 `replaces` 同一個 builtin → halt with `OverrideContractError`，要使用者自己選一個。
- `replaces` 指向不存在的 `skill_id` → warn 但不擋（被 replaces 的目標可能屬於還沒安裝的 marketplace skill）。

## 5. 不可繞過事項（Hard Constraints）

- ❌ 不得直接修改 `<cap_root>/agent-skills/*.md`（這是 builtin 的 prompt 內容）。
- ❌ 不得修改 `<cap_root>/.cap/skills.yaml`（這是 builtin 的 registry）。
- ❌ 不得修改 `<cap_root>/agent-skills/00-core-protocol.md`（這是全域憲法）。
- ❌ 不得繞過 source resolver 直接讀取 `<cap_root>/agent-skills/`：所有讀取必須走 RuntimeBinder / WorkflowLoader / Claude `@` 引用 / Codex `$skill` 映射。
- ✅ 可在 `<project_root>/agent-skills/` 放自訂 prompt file，但僅作為 **`prompt_file` 欄位**的目標路徑；不得期待 `factory.py` 或 mapper 自動 glob 收集（這些 glob 限定於 `<cap_root>/agent-skills/*-agent.md`）。

## 6. 與其他 policy / schema 的關係

- **`policies/agent-registry.md`**：定義 `.cap.agents.json` legacy adapter 與 `.cap.skills.yaml` 的關係；本 policy 補上「為何 agent-skills/ 唯讀」的部分。
- **`schemas/skill-registry.schema.yaml`**：定義 skill registry 的 schema；`disabled` / `replaces` 欄位 normative source 在 schema，本 policy 只解釋語意。
- **`docs/cap/P9-SOURCE-RESOLVER-DESIGN.md`**：定義三層 resolver 的解析順序、`allowed_source_roots` 守護與 binding provenance；本 policy 補上「使用者該怎麼覆蓋」的 how-to。
- **`docs/cap/AGENT-SKILLS-CUSTOMIZATION.md`**：使用者導向 quickstart，承載完整範例與遷移指南。

## 7. Versioning 與 Baseline Snapshot

每次 workflow run 會在 `agent-sessions.json` envelope 內記錄 `agent_skills_baseline`（v0.22.0+）：

```json
{
  "agent_skills_baseline": {
    "cap_version": "0.22.0",
    "git_commit": "4334a62",
    "dir_hash": "sha256:...",
    "prompt_files": {
      "01-supervisor-agent.md": "sha256:...",
      "04-frontend-agent.md": "sha256:..."
    }
  }
}
```

用途：

- **Replay**：日後在 baseline 已升級的環境想重跑某 run，可比對 hash 判斷行為差異。
- **Diff**：稽核可看出當時用的 baseline 與現在 baseline 的差異。
- **Promote / publish**：跨 repo 移植 workflow 時，能精確標明 baseline 版本依賴。

詳細 schema 與計算路徑見 `engine/agent_skills_snapshot.py` 與 `schemas/agent-session.schema.yaml` 的 `agent_skills_baseline` 欄位。
