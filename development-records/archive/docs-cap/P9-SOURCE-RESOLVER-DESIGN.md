# P9 Source Resolver — Design Memo (accepted baseline)

> 本文件是 P9 #2-#5 的設計 baseline。`P9 #1` 已完成（commit `df0cc73`，本機 + origin/main），本 memo 不重述其內容。後續 P9 #2-#5 實作 commit 必須 cross-reference 本 memo 對應段落。
>
> 範圍：workflow / skill 兩條 source layer，各自的 priority、metadata、與 Project Constitution 守護。
> 非範圍：plugin / marketplace 安裝流程、Codex / Claude 原生 SKILL.md export — 對齊 `MISSING-IMPLEMENTATION-CHECKLIST.md` 的 P9 deferred 段。

## 1. 現況（Pre-P9 Baseline）

### 1.1 Workflow source（單一層）
- `engine/workflow_loader.py:WorkflowLoader.workflows_dir` 只指向 `<cap_root>/schemas/workflows/`。
- `load_workflow(ref)` 先試 ref 本身是否為絕對 / 相對路徑，否則 fallback 到 `workflows_dir / ref`。
- `scripts/cap-workflow.sh` 先在 `WORKFLOWS_DIR=schemas/workflows/` 找 `.yaml` / 原檔，再 forward 給 `workflow_cli.py resolve-ref`。
- 沒有 project / shared / builtin 分層概念，使用者要新增 workflow 必須往 `schemas/workflows/` 寫。

### 1.2 Skill registry（單一層 + dual-path）
- `engine/runtime_binder.py:load_skill_registry` 偏好 `<cap_root>/.cap/skills.json`（namespaced），fallback `<cap_root>/.cap.skills.json`（legacy）；亦支援 `registry_ref` 顯式覆寫單一檔。
- 找不到時走 `_load_legacy_registry_adapter`（fallback adapter，標 `_missing=True`）。
- 沒有專案級 skill registry 與 builtin 之間的合併概念；目前 `<cap_root>/.cap/skills.json` **同時**扮演 builtin 與 project（因為 cap-protocols repo 自己就是「兩者」），這個歧義在 P9 #3 必須先消解。

### 1.3 Allowed source roots（已有 workflow side，缺 skill side）
- `schemas/project-constitution.schema.yaml` `workflow_policy` block 已含 `enforce_allowed_source_roots` + `allowed_source_roots`（required 欄位）。
- `engine/runtime_binder.py:_assert_workflow_source_allowed` 已實作：在 `bind_semantic_plan` 開頭檢查 `semantic_plan.source_path` 是否落在 allowed roots 之下，違反 raise `WorkflowSourcePolicyError`。
- **缺**：選定的 skill 來源是否落在 allowed roots 之下，runtime 沒檢查；只要 skill registry 載入成功就照用。
- **缺**：binding report 沒記每個 skill 的來源層（project / builtin / shared），所以 audit 時也看不出來。

### 1.4 Binding report 形狀
- `schemas/binding-report.schema.yaml` 對每個 step entry 已有：`step_id` / `phase` / `capability` / `resolution_status` / `selected_skill_id` / `selected_provider` / `selected_agent_alias` / `selected_prompt_file` / `selected_cli` / `binding_mode` / `missing_policy` / `reason` / `candidate_skill_ids[]`。
- 頂層含 `project_constitution_snapshot` 欄位，描述「已含 binding_policy / allowed_capabilities / source_priority」，**但 `source_priority` 目前 producer 不真實寫入 layer-aware 內容** — 只是 carry-through 字串。

## 2. 設計目標（Goals）

1. **可重現**：同樣的 workflow / skill ref 在相同的專案與相同的 cap_root 下永遠解到同一個檔案，沒有 race。
2. **可審計**：binding report 與 workflow plan 必須能回答「這個 step 的 skill 來自哪裡？這個 workflow 來自哪裡？」
3. **可治理**：Project Constitution `allowed_source_roots` 對 workflow **與** skill 都生效；違反不只 warn，而是 halt（遵循既有 `_assert_workflow_source_allowed` 的精神）。
4. **不破既有**：v0.22.0-rc14 之後沒寫 project-local workflow / skill 的專案，行為不變。
5. **不引入新 namespace**：strategies/ 的 file-based 模式維持；不做 plugin runtime / marketplace。

## 3. Source Layer 層級（Authoritative Order）

CAP 認三個 layer，依序由高到低：

| 名稱 | 路徑（workflow） | 路徑（skill） | 寫入者 | 版本控制 | 預設 allowed |
|---|---|---|---|---|---|
| `project` | `<project_root>/.cap/workflows/` | `<project_root>/.cap/skills.json` 或 `<project_root>/.cap/skills/*.{yaml,json}` | 使用者 / cap project bootstrap | 進專案 git | ✓ |
| `shared` | `<cap_home>/shared/workflows/` | `<cap_home>/shared/skills.json` 或 `<cap_home>/shared/skills/*` | 使用者本機跨專案共用 | 不進 git | ✗（必須在 constitution 顯式加） |
| `builtin` | `<cap_root>/schemas/workflows/` | `<cap_root>/.cap/skills.json` | charlie-ai-protocols repo（即本 repo） | 進 cap-protocols git | ✓ |

**`project` 為何要進專案 git**：本 layer 的目的就是讓使用者 fork CAP 後，自己專案專屬的 workflow / skill 跟著該專案走，不污染 cap-protocols。

**`shared` 為什麼不進 git**：cross-project 個人習慣（例如某個 lighthouse audit workflow 在所有自己的 repo 都想用），但又不想進每個專案。

**`builtin` 是 cap-protocols 自己的 SSOT**：本 repo 的 `schemas/workflows/` + `.cap/skills.json` 只在 cap-protocols 自身被當 builtin。

> 注意 cap-protocols **本身**作為一個專案時的歧義：本 repo 的 `.cap/skills.json` 同時是「對外 builtin」與「本 repo 自己的 project」。本 memo 的處置：當 `project_root == cap_root` 時，`project` layer 與 `builtin` layer 視為同一份 — 不重複載入、不合併。runtime 用 `Path.samefile` 判定。

> 早先 checklist 提到的 `legacy` layer**不採納**：legacy 已被 P0c batch 2.5 dual-path 收斂到 namespaced 版本，剩下的散檔由 `cap project migrate-config` 處理；不再需要 resolver 替它特例化。

## 3.1 預設 `allowed_source_roots` 展開（Default Allowed Roots Policy）

> **裁定**：使用者顯式宣告 `enforce_allowed_source_roots=true` 後，**runtime 自動把 `project` 與 `builtin` layer 的標準路徑當作預設允許**；shared layer 一律不預設允許，使用者要用必須在 constitution 的 `allowed_source_roots` 顯式寫上對應路徑。

### 3.1.1 為什麼有這條
- 沒有預設展開的話，凡是 `enforce_allowed_source_roots=true` 的既有專案在 P9 #2 落地的瞬間會被自己擋死（builtin workflow 解到的 `schemas/workflows/<x>.yaml` 路徑不在 user-declared roots 之下）。
- 反之預設把所有 layer 都自動允許，又把 enforcement 噪音化（shared 是跨 project 個人習慣，治理上應該屬於「opt-in」而非「opt-out」）。
- 折衷：把「同 repo 內顯然要用的東西」（project + builtin）當預設允許，「跨 repo 的個人習慣」（shared）強制走顯式宣告。

### 3.1.2 Implicit allowed roots（runtime 自動注入）
僅當 `enforce_allowed_source_roots=true` 才生效；`false` 時整個 enforcement 跳過。

| Layer | Implicit allowed paths |
|---|---|
| `project` | `<project_root>/.cap/workflows`、`<project_root>/.cap/skills`、`<project_root>/.cap/skills.json` |
| `builtin` | `<cap_root>/schemas/workflows`、`<cap_root>/.cap/skills`、`<cap_root>/.cap/skills.json` |
| `shared` | （無，必須由使用者在 constitution 顯式宣告） |

**展開時機**：在 enforcement 比對之前由 runtime 把 implicit 路徑與 `constitution.allowed_source_roots`（user-declared）做 union，產生 `effective_allowed_roots`，後續所有 enforcement 都以 effective set 比對。

**Implicit 路徑不存在於磁碟上不影響**：路徑不存在但被列為 allowed root 是合法的（沒命中就 fall through 到下一 layer），enforcement 看的是「source_path 是否在某個 allowed root **之下**」，而不是「allowed root 必須先存在」。

### 3.1.3 使用者明確要用 shared layer 怎麼做
在 `<project_root>/.cap/constitution.yaml` 的 `workflow_policy.allowed_source_roots` 顯式列：

```yaml
workflow_policy:
  enforce_allowed_source_roots: true
  allowed_source_roots:
    # implicit project / builtin 由 runtime 自動補；以下是使用者顯式宣告：
    - ~/.cap/shared/workflows
```

**禁止**：在 implicit 名單寫到 constitution（會造成「使用者 vs runtime 誰是 SSOT」的歧義）。runtime 看到 user-declared 名單裡有 implicit 路徑時應該 warn 但不擋（不破壞 backward compat）。

### 3.1.4 與 binding report 的對應
binding report 頂層新增 `effective_allowed_roots` snapshot（見 §6 schema 變動），讓 audit 看得到 implicit + explicit 合併後的最終允許清單。`project_constitution_snapshot` 內保留 user-declared 原文，兩者並存以便回推。

## 4. P9 #2：Workflow Resolver

### 4.1 解析順序
給定 `workflow_ref`（例如 `project-spec-pipeline` 或 `version-control.yaml` 或絕對路徑）：

1. **絕對路徑** → 直接 load。`source_layer` 由 §4.2 規則推。
2. **相對路徑且檔案存在** → 直接 load（相對於 cwd / cap_root）。`source_layer` 由 §4.2 規則推。
3. **以 ref 當 `workflow_id` / 檔名**，依序在 `project` → `shared` → `builtin` 找：
   - 先掃 `project` layer 該 dir 是否有 `<ref>.yaml` / `<ref>.yml` / `<ref>.json`，命中 return（`source_layer=project`）。
   - 否則掃 `shared`，命中 return（`source_layer=shared`）。
   - 否則掃 `builtin`，命中 return（`source_layer=builtin`）。
   - 全部 miss → raise `FileNotFoundError`，錯誤訊息列出三個搜過的目錄。

### 4.2 source_layer 推斷規則（含 explicit）
解析出來的絕對 `path` 對應的 `source_layer` 由下列規則推：

| 條件 | source_layer |
|---|---|
| `path` 在 `<project_root>/.cap/workflows/` 之下（layered hit 或絕對路徑剛好落在這裡） | `project` |
| `path` 在 `<cap_home>/shared/workflows/` 之下 | `shared` |
| `path` 在 `<cap_root>/schemas/workflows/` 之下 | `builtin` |
| 以上皆非（使用者用絕對路徑指向其他位置） | `explicit` |

**`explicit` 的治理含義**：使用者帶外部路徑進來；P9 #5 enforcement 仍適用 — 該路徑必須在 effective allowed roots 之下（§3.1）才放行，否則 raise `WorkflowSourcePolicyError`。

### 4.3 Override vs Extend
- **同 `workflow_id`**：project layer wins（override）。binding report 的 workflow source metadata 必須記 `source_layer=project` + `source_path=...`。
- **新 `workflow_id`**：project 引入 builtin 沒有的 workflow（extend）。同樣記 `source_layer=project`。
- **不允許**：partial override（project 只覆蓋某個 step）。要 override 就整個 workflow override；想增量改的話 fork 出 project workflow 再修。**理由**：semantic plan / compiled workflow gate 都已驗整份 schema，partial merge 會把 schema validation 噪音化。

### 4.4 介面變動
- `WorkflowLoader.__init__(*, base_dir, project_root=None, cap_home=None)` 新增兩個 keyword-only optional argument；缺省由 Python-side helper 解析（explicit kwarg > env > cwd / home fallback），不 shell-out 呼叫 `cap-paths.sh`。
- `WorkflowLoader.load_workflow(ref)` 內部用新 `_resolve_workflow_path(ref) → (path, source_layer)`，回傳 tuple；`load_workflow` 把 `source_layer` 寫進 normalize 後的 `_source_layer` 欄位（既有 `_source_path` 不變）。
- 既有 caller 不需動；新欄位是 additive。

### 4.5 cap-workflow.sh pre-resolve 委派 Python（破壞性必要修正）
**現況問題**：`scripts/cap-workflow.sh:resolve_workflow_ref` 在 bash 端先用 `WORKFLOWS_DIR=schemas/workflows` 做 fast-path stat（line 67-78），再 fall through 給 `workflow_cli.py resolve-ref`。如果 P9 #2 把 layered resolver 寫進 Python 但 bash 仍跑 builtin-only fast-path，**project layer override 會被 bash 偷走**（builtin 同名檔先命中、Python layered resolver 永遠不被觸發）。

**裁定**：bash 端 fast-path 必須移除。`cap-workflow.sh` 收到 ref 後**直接** forward 給 `workflow_cli.py resolve-ref`，由 Python 走完整 layered resolution（含 §4.1 三層 + §4.2 explicit 推斷 + §4.4 介面）。

**具體變更**（P9 #2 commit 內順手做）：
- `cap-workflow.sh:resolve_workflow_ref` 內 `if [ -f "${WORKFLOWS_DIR}/${raw_ref}.yaml" ]` / `if [ -f "${WORKFLOWS_DIR}/${raw_ref}" ]` 兩個 fast-path block 整段刪除。
- 保留「ref 本身就是絕對路徑」的 short-circuit（避免不必要的 Python invocation overhead）。
- `workflow_cli.py resolve-ref` 的 signature 從 `resolve-ref <workflows_dir> <ref>` 改成 `resolve-ref <ref>` — workflows_dir 由 layered resolver 內部解析。
- 既有 `--workflows-dir` flag（若有）改為 deprecated alias，runtime 印 warning 但仍接受，避免外部 caller 立即壞。

**測試影響**：cap-workflow.sh 的 inline test（若存在）需要更新；現有 `version-control` workflow 的解析路徑會從 builtin fast-path 改走 Python，但結果一致（同一個檔）。

### 4.6 測試 case（focused）
1. project workflow 同 id override builtin → loader 回 project path、`source_layer=project`。
2. project workflow 引入新 id → loader 回 project path、`source_layer=project`。
3. project layer 缺、shared layer 有 → loader 回 shared path、`source_layer=shared`。
4. 三層皆缺 → FileNotFoundError，錯誤訊息列三條搜過的路徑。
5. 絕對路徑 ref 落在某 layer root 之下 → `source_layer` 推回該 layer（不是 `explicit`）。
6. 絕對路徑 ref 落在三 layer 之外 → `source_layer=explicit`。
7. cap-protocols 本身：`project_root == cap_root`，project / builtin 視為同一份，不雙載。
8. **bash 委派回歸**：`cap workflow run version-control` 解出來的 path 與 `python workflow_cli.py resolve-ref version-control` 一致（保證 §4.5 的 fast-path 移除沒漏）。

## 5. P9 #3：Skill Registry Precedence

### 5.1 解析順序
給定可選 `registry_ref`：

1. **顯式 `registry_ref`**：行為不變（單一 file load，不合併）。
2. **無 ref**：依序載入三層，**合併**為 single registry：
   - `builtin`（最低）：`<cap_root>/.cap/skills.json` 或 legacy fallback。
   - `shared`（中間）：`<cap_home>/shared/skills.json` 或 `<cap_home>/shared/skills/*.{yaml,json}` 集合。
   - `project`（最高）：`<project_root>/.cap/skills.json` 或 `<project_root>/.cap/skills/*.{yaml,json}` 集合。
3. 合併規則：以 `skill_id` 為 key；高層 wins。`binding_defaults` 採 deep-merge（key-wise override）。

### 5.2 為什麼合併（不像 workflow 那樣單一 file pick）
- skill 的 unit-of-replacement 是「單一 skill_id」，不是整份 registry。使用者的 project 通常只想覆蓋一兩個 skill_id（例如把 `04-frontend` 換成 project-specific 變體），其他 skill 都吃 builtin。
- workflow 的 unit-of-replacement 是整個 workflow file（一連串 step + governance），partial override 反而難治理（見 §4.2）。

### 5.3 Source 追蹤
合併時每個 skill entry 標 `_source_layer` + `_source_path`；不衝到對外 schema（`_*` 是 internal-use field，與既有 `_source_path` / `_missing` / `_adapter_from_legacy` 同模式）。

### 5.4 介面變動
- `RuntimeBinder.load_skill_registry(registry_ref=None)` 行為改：當 `registry_ref` 為 None，內部呼叫新 `_load_layered_skill_registry()` 回合併版；當有 `registry_ref`，沿用單檔 load。
- 新增 `_load_layered_skill_registry()` 私有方法 + 新 `_merge_skill_registries(layers: list[dict]) → dict`。
- `bind_semantic_plan` 內每個 step 的 `selected_skill_id` 對應的 source 由 merge 結果裡的 `_source_layer` / `_source_path` 拉出，寫進 binding report（見 §6）。

### 5.5 測試 case（focused）
1. project skill 同 id override builtin → binding report `selected_skill_id` 對的 `_source_layer=project`。
2. project skill 引入新 id → 同上。
3. project / shared / builtin 三層都缺某 skill → fallback adapter（行為與現況一致）。
4. `registry_ref` 顯式指定單檔 → 不走 layered（regression）。
5. cap-protocols 本身 project=builtin → 不雙載。
6. shared 在中層，被 project override → binding report 顯示 project wins。

## 6. P9 #4：Binding Report Source Metadata

### 6.1 schema 變動（`schemas/binding-report.schema.yaml`）
新增 optional 欄位（保持 backward compatible）：

```yaml
properties:
  workflow_source:
    type: object
    description: Source layer + absolute path of the workflow that drove this binding (P9 #4).
    properties:
      source_layer: {type: string, enum: [project, shared, builtin, explicit]}
      source_path:  {type: string}
  effective_allowed_roots:
    type: array
    description: |
      Snapshot of effective allowed_source_roots after merging runtime-injected
      implicit project / builtin defaults (§3.1) with constitution-declared roots.
      Empty array means enforcement was disabled (enforce_allowed_source_roots=false).
    items: {type: string}
  steps:
    items:
      properties:
        skill_source:
          type: [object, "null"]
          description: Source layer + absolute path of the selected skill (null when fallback adapter or unresolved).
          properties:
            source_layer: {type: string, enum: [project, shared, builtin, explicit, fallback]}
            source_path:  {type: [string, "null"]}
```

### 6.2 Producer 變動
- `RuntimeBinder.bind_semantic_plan` 結尾組裝 binding report 時，從 semantic plan 的 `_source_layer` / `_source_path` 帶入頂層 `workflow_source`。
- 每個 step entry 從合併過的 registry entry 的 `_source_layer` / `_source_path` 帶入 `skill_source`。fallback 走 `builtin-shell` adapter 時，`source_layer="fallback"`、`source_path=null`。
- `_legacy_registry_adapter` 路徑：`source_layer="fallback"`，與 `_adapter_from_legacy=true` 同義。

### 6.3 與 `project_constitution_snapshot` 既有 `source_priority` 欄位的關係
- `project_constitution_snapshot.source_priority` 維持「使用者宣告的優先順序」（從 constitution 拉出來的 carry-through 字串）。
- `workflow_source` / `skill_source` 是「runtime 實際解析的結果」。
- 兩者**互不取代**：前者是 input policy，後者是 output evidence。memo 在實作時要在 schema description 互相 cross-reference。

### 6.4 測試 case
- binding report fixture 加 layered scenarios，驗 `workflow_source.source_layer` 與每個 `steps[*].skill_source.source_layer` 對齊預期。

## 7. P9 #5：Allowed Source Roots Enforcement Timing

### 7.1 既有
`_assert_workflow_source_allowed` 在 `bind_semantic_plan` 第一步就跑（見 §1.3）。違反 raise `WorkflowSourcePolicyError`，halt 整個 binding。

### 7.2 缺口
- `allowed_source_roots` 只規範 workflow，沒規範 skill。
- 對 layered resolver 來說，「合併出來」的 skill registry 可能混合 project / shared / builtin 來源；任一來源不在 allowed roots 之下都應該擋。
- 既有 `_assert_workflow_source_allowed` 直接拿 `constitution.allowed_source_roots` 比對；P9 引入 implicit 預設展開（§3.1）後，必須改成跟 effective set 比對，不然每個既有 `enforce_allowed_source_roots=true` 的專案會被自己的 builtin workflow 擋死。

### 7.3 提議：把 enforcement 拆成兩個 hook，timing 不同

| Hook | 時機 | 對象 | 違反處置 |
|---|---|---|---|
| `_assert_workflow_source_allowed`（既有，需升級） | `bind_semantic_plan` 開頭、registry 載入前 | semantic_plan.source_path（含 layered hit + explicit absolute path） | raise `WorkflowSourcePolicyError`，halt 整個 binding |
| `_assert_skill_source_allowed`（新增） | 每個 step 解析完選定 skill 之後、寫進 step report 之前 | 該 step 選定 skill 的 `_source_path` | raise `SkillSourcePolicyError`，halt 整個 binding（**不**降級為 fallback；source policy 是治理紅線） |

兩個 hook **共用** `_compute_effective_allowed_roots(project_context)` helper：把 §3.1 的 implicit project + builtin 預設與 `constitution.allowed_source_roots` (user-declared) 取 union，作為 enforcement 比對的單一 source of truth。binding report 頂層 `effective_allowed_roots` 由同一個 helper 產出 snapshot（§6.1）。

### 7.4 為什麼 skill side 也是 halt 而不是降級
- `allowed_source_roots` 是 Project Constitution 上的硬性宣告，違反代表「使用者承諾的隔離邊界被破壞」。
- 若降級為 fallback，binding report 上會看到 `selected_skill_id` 是 fallback 而非真實選擇 — 治理痕跡反而被遮蔽。
- 治理紅線優先於可用性。如果使用者要放寬，應該改 constitution 而非靠降級。

### 7.5 enforcement 範圍邊界
- `enforce_allowed_source_roots=false` → 兩個 hook 全部跳過，`effective_allowed_roots=[]`（空陣列當作 sentinel 標明「未啟用」）；行為與現況完全一致。
- 三層解析 **沒命中**（找不到任何 skill）→ 走既有 `unresolved_required` / `optional_unresolved` 流程，不觸發本 enforcement（因為沒有 source 可審）。
- `registry_ref` 顯式指定單檔（§5.1 path 1）→ enforcement 仍適用（顯式 ref 也要在 effective allowed roots 之下）。
- `source_layer=explicit`（絕對路徑落在三 layer 之外）→ 仍進 enforcement，必須在 effective set 之下才放行。
- `source_layer=shared` 但使用者沒在 constitution 顯式宣告 shared 路徑 → halt（這就是 §3.1 預設策略生效的地方）。
- 三層 layer 路徑（cap-protocols 本身的 project=builtin 重合）→ 視為單一來源做一次檢查，不 double-fire。

### 7.6 測試 case
1. project skill 在 `<project_root>/.cap/skills.json`，即使 user-declared roots 沒寫 `.cap/skills.json`，仍因 implicit project root → pass。
2. builtin skill 在 `<cap_root>/.cap/skills.json`，即使 user-declared roots 沒寫 cap_root，仍因 implicit builtin root → pass。
3. shared skill 不在 user-declared roots → halt with `SkillSourcePolicyError`。
4. explicit registry_ref / explicit workflow path 落在 effective roots 外 → halt with source-policy error。
5. enforcement 關閉（`enforce_allowed_source_roots=false`）→ pass，behaviour 與現況一致。
6. 同一 binding 內 workflow 與 skill 都被擋：以 workflow 為先（既有行為），不會走到 skill check。

## 8. 實作順序（Implementation Sequencing）

對齊 P9 #2-#5 的 sub-item 邊界：

1. **P9 #2** — `WorkflowLoader` 三層 resolver + `_source_layer` 欄位 + 8 個 focused test。**不**動 RuntimeBinder。
2. **P9 #3** — `RuntimeBinder.load_skill_registry` 三層 merge + 6 個 focused test。**不**動 schema。
3. **P9 #4** — `binding-report.schema.yaml` 加 optional `workflow_source` + `steps[*].skill_source`；producer 寫入；schema validate test 升級。
4. **P9 #5** — 新增 `_compute_effective_allowed_roots` + 升級既有 `_assert_workflow_source_allowed` 使用 effective set + 新增 `_assert_skill_source_allowed` + focused tests。

每個 sub-item 是獨立 commit，每個都帶 focused test 與 checklist 更新；全綠後才開下一個。

## 9. Design Decisions（review 後裁定）

### 9.1 已裁定（記錄結論）
- **shared layer v1 範圍**：三層皆實作；shared 路徑解析照走，但**預設不在 `effective_allowed_roots`**（§3.1）；使用者要 opt-in 必須在 constitution 顯式宣告 shared 路徑。
- **partial override 禁令**：保留（§4.3）。未來若有強需求由 ADR 推翻，本 memo 採保守。
- **`Source Policy` exception 基底**：`WorkflowSourcePolicyError` 與 `SkillSourcePolicyError` 共同繼承新增的 `SourcePolicyError` base，上游可以用一個 `except` 抓兩種。
- **cap-workflow.sh pre-resolve**：bash 端 `WORKFLOWS_DIR` fast-path 必須在 P9 #2 commit 內**整段移除**（§4.5），改成直接 forward 給 Python；否則 project layer override 會被 bash builtin fast-path 偷走。
- **預設 allowed roots 策略**：project + builtin 預設展開為 implicit allowed；shared 不預設允許（§3.1）。
- **project_root helper**：採 Python-side helper，不在 `WorkflowLoader` 內 shell-out 呼叫 `cap-paths.sh`。P9 #2 可以先用 `WorkflowLoader.__init__(project_root=None, cap_home=None)` 的私有 helper 解決，若 P9 #3/#5 也需要同邏輯，再抽成 `engine/source_paths.py`。Precedence：explicit kwarg > env (`CAP_PROJECT_ROOT` / `CAP_HOME`) > cwd / `Path.home()/.cap` fallback；不得在 library helper 內啟動 shell 子行程，避免測試與 API consumer 出現隱性 I/O。
- **memo / spec 形式**：保留 `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` 作為 design rationale，不改名 `SOURCE-RESOLVER.md`。實作完成後在 `MISSING-IMPLEMENTATION-CHECKLIST.md` 與 `docs/cap/ARCHITECTURE.md` cross-reference；若未來 resolver contract 穩定到需要使用者文件，再另立短版 spec。

## 10. Acceptance Checklist（memo 自身）

Memo 通過後：
- 先 commit memo（doc-only）作為 P9 #2-#5 的設計 baseline。
- 實作 P9 #2-#5 依 §8 順序，每個 sub-item 一個 commit；commit message 要 cross-reference 本 memo 對應段落（例如 P9 #2 reference §4.1 / §4.2 / §4.5）。
- 每個 sub-item 完成後更新 `MISSING-IMPLEMENTATION-CHECKLIST.md` 對應條目從 `[ ]` 到 `[x]`。
- P9 整段（#1-#5）全綠後再考慮是否 cut `v0.22.0-rc15`。

## 11. Binding Provenance Audit Checklist（A0 #3, post-P9）

> 本節為 A0 系列補上的 audit clarification。P9 #4 已在 schema 與 producer 落地以下欄位；本節彙整給 audit / review 用。

每份 binding report 應同時提供下列四項 provenance 線索；缺一視為 binding pipeline 異常：

| # | 欄位 | 路徑 | 用途 |
|---|---|---|---|
| 1 | `selected_skill_id` | `binding.steps[*].selected_skill_id` | 該 step 實際選中哪個 skill；`null` 表示 unresolved / blocked |
| 2 | `skill_source.source_layer` | `binding.steps[*].skill_source.source_layer` | 來源層（`project` / `shared` / `builtin` / `explicit` / `fallback`）；`fallback` 標示 builtin-shell 或 legacy-adapter 合成 |
| 3 | `skill_source.source_path` | `binding.steps[*].skill_source.source_path` | 該 skill 的絕對 registry 路徑；`null` 限定於 fallback / 合成情境 |
| 4 | `resolution_status` + `reason` | `binding.steps[*].resolution_status` / `binding.steps[*].reason` | 涵蓋 `resolved` / `fallback_available` / `required_unresolved` / `optional_unresolved` / `incompatible` / `blocked_by_constitution` 與人類可讀理由 |

額外的頂層 provenance 欄位：

- `workflow_source.source_layer` / `workflow_source.source_path`：本次 binding 用的 workflow 檔的來源層與絕對路徑（P9 #4 §6.1）。
- `effective_allowed_roots`：本次 binding 實際比對用的 allowed roots（user-declared ∪ implicit project + builtin；P9 #5 §3.1.4）。
- `registry_source_path`：合併過的 registry 任一具體來源（first source path）。
- `adapter_from_legacy` / `registry_missing`：標示是否走 legacy `.cap.agents.json` 適配或完全找不到 registry。

### 11.1 V0.22.0+ override 契約對 audit 的影響

A0 #2 引入 `disabled` / `replaces` 後，audit checklist 補：

- 對於被 mask 的 skill_id（不論 `disabled: true` 或被 `replaces` 鎖定），合併後的 registry 會在內部標 `_masked: true` + `_mask_reason`。
- Binding report **不**直接暴露 `_masked` 條目，但對於原本可能命中的 capability，`steps[*].reason` 應反映 mask 結果（例如 `"target skill_id 'builtin-figma' is masked by project layer"`）。
- 真正的 audit 用法：跑 `cap workflow bind` 與 `cap workflow plan` 時對照 `effective_allowed_roots` 與 `skill_source.source_layer`，確認 mask / replace 行為符合 `<project_root>/.cap/skills.yaml` 宣告。

### 11.2 跑 audit 的最小命令

```bash
cap workflow bind <workflow-id> | jq '{
  workflow_source,
  effective_allowed_roots,
  registry_source_path,
  adapter_from_legacy,
  registry_missing,
  steps: [.steps[] | {
    step_id,
    capability,
    resolution_status,
    selected_skill_id,
    skill_source,
    reason
  }]
}'
```

預期：每個 required step 都有 non-null `selected_skill_id` 與對應 `skill_source.source_layer`；`source_layer = project` 的 step 應對應到 `<project_root>/.cap/skills.yaml`；`source_layer = builtin` 的 step 應對應到 `<cap_root>/.cap/skills.yaml`。

### 11.3 與 baseline snapshot 的關係

A0 #4 在 `agent-sessions.json` envelope 加 `agent_skills_baseline`（dir_hash + per-file hash）。Audit 時可同步檢查：

- 該 run 用的 builtin baseline 是否與當前 cap-protocols repo HEAD 一致。
- 若不一致，binding report 的 `skill_source.source_layer = builtin` step 是否仍能 replay。

詳見 [`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md) §7 與 [`docs/cap/AGENT-SKILLS-CUSTOMIZATION.md`](AGENT-SKILLS-CUSTOMIZATION.md)。
