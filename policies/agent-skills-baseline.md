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
