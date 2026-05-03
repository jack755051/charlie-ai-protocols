# Project vs Task Constitution Boundary (P2 #1)

> **Scope**: P2 第一塊基石。在動 CLI / validator / snapshot / promote 之前先把 Project Constitution 與 Task Constitution 在 5 個 surface（CLI / workflow / capability / schema / storage）的分流寫清楚，後續所有 P2 子任務都以本 memo 為錨。
>
> **Status**: design memo — proposes the canonical boundary; does not change runtime code in this commit.
>
> **Reviewers**: 使用者最終裁決 §4「Proposed Boundary」是否拍板，再進 P2 #2（CLI 落地）。

## 1. Why This Memo Exists

CAP 同一個詞「constitution」在 runtime 中有兩種完全不同的語意：

- **Project Constitution**：repo 級長期治理憲章。產出 `.cap.constitution.yaml`（repo SSOT）+ snapshot；schema 為 `schemas/project-constitution.schema.yaml`；單一 repo 一份；跨多次 task 重用；定義 source_of_truth / runtime_workspace / binding_policy / workflow_policy / allowed_capabilities 等治理欄位。
- **Task Constitution**：單次 prompt 的執行憲章。產出 `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json`；schema 為 `schemas/task-constitution.schema.yaml`；每個 prompt 一份；定義 task_id / goal / goal_stage / success_criteria / non_goals / execution_plan 等執行欄位。

**現況**：兩者在 CLI 命名與 storage 路徑兩個 surface 上**完全沒有區分**。`cap workflow constitution` 字面上像是建 project constitution，實際上產出 task constitution（連 `engine/workflow_cli.py:cmd_print_constitution_report` 都把標題印成 `"TASK CONSTITUTION"`）。Storage 也共用同一個 `~/.cap/projects/<id>/constitutions/` 平面目錄，filename prefix `constitution-<stamp>.json` 沒有 type discriminator。

**為什麼這是阻塞 P2**：P2 要新增 `cap project constitution "<prompt>"`、`--dry-run`、`--from-file`、`--promote`，還要在 storage 開新層級 `~/.cap/projects/<id>/constitutions/project/<stamp>/...`。若不先把現有 namespace 拆清，新加的 CLI / storage 會跟既有的混淆，validator 與 promote 邏輯會踩到 type discriminator 缺失的坑。

## 2. Current State Survey

### 2.1 CLI Surface（衝突最嚴重）

| Command | 實際產出 | Schema 檔 | Storage 路徑 | 命名是否誤導 |
|---|---|---|---|---|
| `cap workflow run project-constitution <prompt>` | **Project** constitution（跑完整 5-step workflow）| `project-constitution.schema.yaml` | `.cap.constitution.yaml` + `~/.cap/projects/<id>/constitutions/<timestamp>.json` | ✓ 命名清楚（workflow_id 直接點名）|
| `cap workflow constitution <prompt>` | **Task** constitution（call `TaskScopedWorkflowCompiler.build_task_constitution`）| `task-constitution.schema.yaml` | `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json` | ⚠️ **嚴重誤導** — 字面像 project 實際 task |
| `cap workflow compile <prompt>` | Task constitution + capability graph + compiled workflow（bundle）| 多份 | 同上 + `compiled-workflows/` + `bindings/` | 命名合理 |
| `cap workflow run-task <prompt>` | Task constitution + execute compiled workflow | 同上 | 同上 + `reports/workflows/<wf>/<run>/` | 命名清楚 |
| `cap workflow run <id> [<prompt>]` | 跑指定 workflow（id 已知）| n/a | `reports/workflows/<id>/<run>/` | 命名清楚 |

`cap workflow constitution` 是最劇毒的命名：兩個 token（`workflow` + `constitution`）裡的後者在 CAP 詞彙中最常被理解為「Project Constitution」（憲法的長期語意），但這個 CLI 實際只做 task scoped compile 的第一步。

### 2.2 Workflow Surface（已分流，命名清楚）

- `schemas/workflows/project-constitution.yaml` — Project Constitution 完整 pipeline（bootstrap → normalize → draft → validate → persist），由 `cap workflow run project-constitution` 觸發。
- `schemas/workflows/project-constitution-reconcile.yaml` — Addendum reconcile workflow（吸收後續補充再重構憲法）。
- `schemas/workflows/project-spec-pipeline.yaml` / `project-implementation-pipeline.yaml` / `project-qa-pipeline.yaml` — per-stage pipelines；其首步 `draft_task_constitution` 屬於 **Task** constitution 範疇，不混淆。

Workflow YAML 層面的命名沒有實質衝突。

### 2.3 Capability Surface（已分流，但命名不對稱）

| Capability | 屬於 | 用於 |
|---|---|---|
| `bootstrap_platform_defaults` | Project | 從 schemas/ 抽 required 欄位給 draft 抄 |
| `project_constitution` | Project | Supervisor draft Project Constitution |
| `constitution_validation` | Project | jsonschema 驗 Project Constitution |
| `constitution_persistence` | Project | 寫 `.cap.constitution.yaml` + snapshot |
| `prompt_outline_normalize` | 通用（Project / Task 共用）| 把 prompt 拆成 scalar / array / object / markdown buckets |
| `task_constitution_planning` | Task | Supervisor 建 Task Constitution |
| `task_constitution_persistence` | Task | 寫 `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json` |
| `handoff_ticket_emit` | 通用 | Type C ticket emission |

**不對稱觀察**：Project 側的 `constitution_validation` / `constitution_persistence` 沒有 `project_` prefix，但 Task 側的 `task_constitution_*` 有 `task_` prefix。歷史包袱，可在 P2 階段不動 capability 名（避免破壞 .cap.skills.yaml binding），改用 doc + comment 釐清歸屬。

### 2.4 Schema Surface（已分流，無衝突）

- `schemas/project-constitution.schema.yaml` — Project Constitution（draft v1 完整治理欄位）
- `schemas/task-constitution.schema.yaml` — Task Constitution（v0.21.1+ 嚴格 8 頂層欄位）
- 兩 schema 各自有 fixture cases / test 套件 / validator subcommand。

無實質衝突。

### 2.5 Storage Surface（衝突嚴重）

**現況**（混合）：

```text
~/.cap/projects/<project_id>/
├── constitutions/                      <-- ❌ 兩種 constitution 共用同一目錄
│   ├── constitution-<stamp>.json       <-- 可能是 task 也可能是 project，無 discriminator
│   └── token-monitor-min-spec.json     <-- 歷史命名亂入
├── compiled-workflows/<stamp>.json     <-- task only
├── bindings/<stamp>.json               <-- task only
├── handoffs/<step_id>.ticket.json
├── reports/workflows/<wf>/<run_id>/
└── ... (logs / drafts / sessions / cache / workspace)
```

`cap workflow constitution`（task）與 `cap workflow run project-constitution`（project）的 snapshot 都落在 `constitutions/`，靠 filename 巧合區分（task 走 `constitution-<stamp>.json`，project workflow 走 `<task_id>-<stamp>.json` 之類），但**沒有正式的 type discriminator**。

P2 brief 明確要求：

> 實作 snapshot storage：`~/.cap/projects/<project_id>/constitutions/project/<stamp>/`
> 保存 project-constitution.md / project-constitution.json / validation.json / source-prompt.txt

這意味著要在 `constitutions/` 下開 `project/` subdir，並把 task constitution 對稱地放到 `task/` subdir。

## 3. The Real Problem in One Line

> **Constitution 是兩個不同層級的東西，但 CLI 與 storage 兩個 surface 假裝它們是同一個東西。**

Schema 層級的分流早就做完，Workflow 與 Capability 層級也清楚；卡住的是 user-facing 的兩件事：CLI 命名 + storage 路徑。

## 4. Proposed Boundary（P2 #1 拍板對象）

### 4.1 CLI Namespace

| Command | Constitution type | Status | Notes |
|---|---|---|---|
| `cap project constitution <prompt>` | **Project** | **NEW (P2 #2)** | 推薦 UX。Wrapper 內部呼叫 `cap workflow run project-constitution`，加上 P2 brief 要求的 snapshot storage 與 `--promote` 等旗標 |
| `cap project constitution --dry-run` | Project | NEW (P2) | preview 不寫 snapshot / `.cap.constitution.yaml` |
| `cap project constitution --from-file <path>` | Project | NEW (P2) | 跳過 AI draft，直接驗 + persist 既有檔 |
| `cap project constitution --promote` | Project | NEW (P2) | 把已驗證 snapshot 寫回 `.cap.constitution.yaml`（promote target 詳 §4.5） |
| `cap workflow constitution <prompt>` | **Task** | **DEPRECATED (P2 #2)** | 命名誤導；保留路徑但 emit deprecation warning，建議改用 `cap task constitution` |
| `cap task constitution <prompt>` | Task | **NEW alias (P2 #2)** | 與 `cap project constitution` 對稱命名；底層直接呼叫既有 `compiler.build_task_constitution` |
| `cap workflow compile <prompt>` | Task（含 graph + workflow）| KEEP | 命名合理 |
| `cap workflow run-task <prompt>` | Task（compile + run）| KEEP | 命名合理 |
| `cap workflow run project-constitution <prompt>` | Project（直接跑 workflow）| KEEP（low-level escape hatch）| 給需要 raw workflow 控制的進階使用者；新使用者推 `cap project constitution` |
| `cap workflow run <id> [<prompt>]` | 跑任何 workflow | KEEP | 通用入口 |

**鐵則 — CLI 命名讀法**：
- `cap project ...` 永遠是 **Project Constitution / Project Storage / Project Identity** 範疇。
- `cap task ...` 永遠是 **Task Constitution / Task-scoped runtime** 範疇。
- `cap workflow ...` 永遠是 **Workflow 編排 / 運行** 範疇（與 constitution type 正交）。
- `cap workflow constitution` 與 `cap workflow compile` 屬於 task-scoped 編排，但歷史包袱讓前者命名衝突 → 進 deprecation。

### 4.2 Workflow Surface

無變動。`schemas/workflows/project-constitution.yaml` 既是 Project Constitution 的權威 pipeline，`cap project constitution` CLI 不重做這條 workflow，而是 wrap `cap workflow run project-constitution` 並補強：

1. 把 user prompt 寫成 `source-prompt.txt`（snapshot 保存）
2. 跑完 workflow 後把 markdown / json / validation report 整理成 `~/.cap/projects/<id>/constitutions/project/<stamp>/` 結構
3. 提供 `--from-file` 跳過 AI draft 的 import 路徑
4. 提供 `--promote` 把 snapshot 升回 repo SSOT

### 4.3 Capability Surface

無變動（避免破壞 .cap.skills.yaml binding）。但在 doc 層補一張對照表，明示每個 capability 的 Project / Task 歸屬（§2.3 那張表將被搬到 ARCHITECTURE.md 或保留在本 memo 作為參照）。

### 4.4 Schema Surface

無變動。Validator 邏輯（P2 brief 的「實作 Project Constitution validator」）僅是把現有 `schemas/project-constitution.schema.yaml` 的驗證接到 `cap project constitution --from-file` 與其他入口，**不**重做 schema 本身。

### 4.5 Storage Surface（**核心變動**）

**新層級結構**：

```text
~/.cap/projects/<project_id>/
├── constitutions/
│   ├── project/                                <-- 新增子層
│   │   └── <stamp>/                            <-- 一次 project constitution 落地一個 dir
│   │       ├── project-constitution.md         <-- markdown 形態
│   │       ├── project-constitution.json       <-- JSON 形態
│   │       ├── validation.json                 <-- jsonschema 驗證結果
│   │       └── source-prompt.txt               <-- 原始 user prompt
│   └── task/                                   <-- 新增子層（migrate 既有 task constitution）
│       └── constitution-<stamp>.json           <-- task constitution snapshot（單檔，sticking with current shape）
├── compiled-workflows/<stamp>.json
├── bindings/<stamp>.json
└── ... (其他不動)
```

**Migration 策略**（P2 #2 / #3 須處理）：
- **Project 側**：第一次 `cap project constitution` 跑時直接寫到 `constitutions/project/<stamp>/`；既有 `.cap.constitution.yaml` 不動，保留為 repo SSOT。
- **Task 側**：既有 `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json` 平面檔不強制 migration（風險高、cap-workflow-exec.sh 等多處可能 hard-code 路徑）；改採「新檔走 task/」+「舊檔保留為 legacy 路徑，read-only」的雙存策略。後續可在 P11 promote workflow 一起重構。

**Promote target（§4.5 子問題）**：

P2 brief 列出兩個候選 promote target：
- `.cap.constitution.yaml`（既有 repo SSOT，YAML 格式）
- `docs/cap/constitution.md`（人類可讀 markdown，新檔）

**建議**：promote target 為 **`.cap.constitution.yaml`**，理由：
1. `.cap.constitution.yaml` 已是 producer/consumer SSOT（`engine/project_context_loader.py:_load_yaml` 讀它、`scripts/workflows/persist-constitution.sh` 寫它）。
2. `docs/cap/constitution.md` 屬於 **人類導讀**，由 README 風格管線導向，不該成為 runtime SSOT；可由 `cap project constitution --promote` 同時更新 markdown，但**權威來源是 yaml**。
3. P2 brief 寫的 `docs/cap/constitution.md` 路徑應理解為 markdown 副本，不是 promote 主目標。

最終 promote 行為：`cap project constitution --promote <stamp>` 會：
1. 讀 `~/.cap/projects/<id>/constitutions/project/<stamp>/project-constitution.json`
2. 重新跑一次 schema validation
3. 寫回 `<repo_root>/.cap.constitution.yaml`（YAML 反序列化）
4. （可選）同步寫 `<repo_root>/docs/cap/constitution.md`（markdown 副本）
5. 紀錄 promote 動作到 ledger / run state

## 5. Documentation of `constitution / compile / run-task / run` 差異

P2 brief 明確要求文件化這 4 個命令的差異。提供以下 mapping table（將寫入 `scripts/cap-entry.sh` 的 help 區塊與 `docs/cap/ARCHITECTURE.md`）：

| Command | 輸入 | 是否跑 workflow | 是否實際執行 sub-agent | 是否寫 repo | 主要 artifact |
|---|---|---|---|---|---|
| `cap project constitution <prompt>` | user prompt | ✓（project-constitution.yaml）| ✓（draft step）| ✗（除非 `--promote`）| 4 件套 snapshot in `constitutions/project/<stamp>/` |
| `cap workflow constitution <prompt>` ⚠️ deprecated | user prompt | ✗（純 in-memory compiler）| ✗ | ✗ | task constitution JSON only |
| `cap task constitution <prompt>`（規劃中）| user prompt | ✗（純 in-memory compiler）| ✗ | ✗ | task constitution JSON only（與 deprecated `cap workflow constitution` 等效）|
| `cap workflow compile <prompt>` | user prompt | ✗（純 compile bundle）| ✗ | ✗ | task constitution + capability graph + compiled workflow + binding（compile bundle）|
| `cap workflow run-task <prompt>` | user prompt | ✓（compiled workflow）| ✓ | ✗（除非 workflow step 寫）| compile bundle + workflow run artefacts |
| `cap workflow run <id> [<prompt>]` | workflow id（+ optional prompt）| ✓（指定 workflow）| ✓ | ✗（除非 workflow step 寫）| workflow run artefacts |

**讀法**：縱向看每個 command 的能力剖面；橫向看不同 command 在同一 dimension 的差異。

## 6. Implementation Order for P2（建議）

依本 memo 邊界推導出的 P2 子任務順序：

| # | 子任務 | 變動範圍 | 阻塞下一步？ |
|---|---|---|---|
| **P2 #1** | 本 memo（boundary）| docs only | ✓（後續所有任務的錨）|
| P2 #2 | `cap project constitution <prompt>` happy-path（含 snapshot 4 件套寫入 `constitutions/project/<stamp>/`）| `scripts/cap-project.sh` 加 `constitution` subcommand + 新增 `engine/project_constitution_runner.py`（wrap workflow + snapshot）| 是 |
| P2 #3 | Validator hooks（jsonschema 驗 + halt on fail）| `engine/project_constitution_runner.py` | 部分 |
| P2 #4 | `--dry-run` / `--from-file` flags | 同上 | 否 |
| P2 #5 | `--promote` flag + repo target 寫回 | 同上 + `scripts/workflows/persist-constitution.sh` 拆 helper | 否 |
| P2 #6 | `cap task constitution <prompt>` alias + `cap workflow constitution` deprecation warning | `scripts/cap-workflow.sh` + 新增 `cap task` 入口（或 nest 在 cap-project.sh 裡）| 否 |
| P2 #7 | `cap-entry.sh` help 補 §5 對照表；`docs/cap/ARCHITECTURE.md` 補 boundary 章節 | docs only | 否 |
| P2 #8 | smoke tests（init → constitution → status / doctor 驗 happy path）| `tests/scripts/test-project-constitution.sh` 新增 | 是（release gate）|

**P2 #1 完成後請使用者拍板邊界**，再進 P2 #2。本 memo 不假設任何 runtime 行為被改寫，僅為設計依據。

## 7. Open Questions（need user decision）

1. **`cap task` 入口要新建還是寄居 `cap-project.sh`？**
   - 選 A：新建 `scripts/cap-task.sh`，與 `cap-project.sh` 對稱
   - 選 B：在 `scripts/cap-project.sh` 加 `task` 子命令（cap project task constitution）
   - 選 C：暫不開 `cap task` 入口，先把 deprecation warning 加進 `cap workflow constitution`，等 P2 後續再決定
   - **建議 A**：對稱命名，未來 `cap task plan` / `cap task compile` / `cap task run` 都有清楚 home。
2. **`docs/cap/constitution.md` 是否同步寫？**
   - 選 A：`cap project constitution --promote` 預設只寫 `.cap.constitution.yaml`，`--promote --write-markdown` 才寫 markdown。
   - 選 B：永遠雙寫（YAML + Markdown）。
   - **建議 A**：避免 markdown 與 yaml 漂移（雙寫須額外 lint 對齊）；markdown 副本由獨立 `cap project constitution --emit-markdown` 子動作處理。
3. **既有 `~/.cap/projects/<id>/constitutions/constitution-<stamp>.json` 是否強制 migration 到 `task/<stamp>/`？**
   - 選 A：強制 migration（risky，可能踩到 cap-workflow-exec.sh 對舊路徑的 hard-code 假設）
   - 選 B：新檔走 `task/`、舊檔保留 read-only、不 migrate
   - **建議 B**：避免破壞既有 workflow run。在 P11 promote workflow 統一處理 legacy artefact。

請使用者就這 3 點裁示後再進 P2 #2。

## 8. Cross-References

- 本 memo 的政策依據：`policies/constitution-driven-execution.md`（憲法驅動執行的 mode A/B/C 定義）。
- Storage 路徑契約：`policies/cap-storage-metadata.md` §1（storage location SSOT）。
- 既有 Project Constitution workflow：`schemas/workflows/project-constitution.yaml`。
- 既有 Task Constitution schema：`schemas/task-constitution.schema.yaml`（v0.21.1+ 嚴格 8 欄位）。
- 既有 Project Constitution schema：`schemas/project-constitution.schema.yaml`（draft v1）。
- P2 brief：使用者 P1 closeout 後給的 P2 任務清單（含 `cap project constitution` 4 個 flag、4 件套 snapshot、promote target 候選）。
