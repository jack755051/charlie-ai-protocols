# Orchestration Storage & Compile/Bind Transition Boundary (P3 #5)

> **Scope**: P3 #5 第一塊基石。在動 storage writer / compile-bind reader / workflow YAML 之前，先把 envelope 落地路徑、four-part snapshot 結構、compile/bind 從 legacy reconstruct 切到 envelope-driven 的 transition 規則、以及舊 task-scoped flow 的 backward compatibility 全部寫清楚。
>
> **Status**: design memo — proposes the canonical boundary; does not change engine code in this commit. Per the user's explicit scope guard for the P3 #5 ratification, the memo commit is doc-only.
>
> **Reviewers**: 使用者最終裁決 §4「Proposed Boundary」是否拍板，再進 P3 #5-a（storage writer 純寫入端落地）。
>
> **Tagging baseline**: 本 memo 起草於 `v0.22.0-rc3` tag 之上，`d7e5358` (P3 #4) HEAD 已對齊 origin/main。

## 1. Why This Memo Exists

P3 #4 把 supervisor envelope 的 runtime gate 接好（`scripts/workflows/validate-supervisor-envelope.sh` + `supervisor_envelope_validation` capability），但**驗過的 envelope 沒地方落地**、**compile/bind 仍走 legacy reconstruct path**、**新舊 SSOT 並存卻沒切換策略**。三件事彼此糾纏，若不先拍板邊界就動 engine：

1. **Storage 寫入時機未定**：envelope validation 通過時要不要寫 four-part snapshot？validation 失敗時要不要寫 partial state（仿 P2 Q2 = A）？
2. **Compile/bind 切換策略未定**：`engine/task_scoped_compiler.compile_task` 目前接 `source_request: str` 純函式 reconstruct task_constitution / capability_graph；envelope-driven 要從 envelope 讀，**但 legacy caller**（`cap workflow compile` / `cap workflow run-task` 等）**還是走 source_request path**。一刀切 envelope-driven 會破壞既有行為。
3. **Workflow YAML wiring 未定**：`schemas/workflows/*.yaml` 沒任何 step 引用 `supervisor_envelope_validation`，是放 per-stage pipeline 第一步、放 project-constitution 後接、還是另開新 workflow？這個決策 ripple 進整個 P3 後半段。

P3 #5 brief 已拍板拆三 commit（5-a / 5-b / 5-c），本 memo 把每個 commit 的**邊界與規則**寫死，避免實作時跨刀。

**為什麼這是阻塞 P3 後半段**：P3 #5-b 動 `compile_task` 是 P3 系列最敏感的改動（多處 caller 依賴它）；P3 #5-c 動 workflow YAML 是「envelope flow 對外正式啟用」的開關；P3 #5-a 是純寫入端鋪墊，但寫入位置與 stamp 規則必須與 §4.1 一次定死，否則 5-b/5-c 會撞牆。

## 2. Current State Survey

### 2.1 Storage Surface（envelope 沒有 home）

P2 closeout 後 `~/.cap/projects/<id>/` 已有兩個結構化 snapshot 子層：

```text
~/.cap/projects/<project_id>/
├── constitutions/
│   ├── project/<stamp>/                            # P2 four-part snapshot
│   │   ├── project-constitution.md
│   │   ├── project-constitution.json
│   │   ├── validation.json
│   │   └── source-prompt.txt
│   └── constitution-<stamp>.json                   # legacy task constitution flat file
├── compiled-workflows/<stamp>.json
├── bindings/<stamp>.json
├── handoffs/<step_id>.ticket.json                  # Type C
├── reports/workflows/<wf>/<run_id>/                # workflow run artefacts
└── (no orchestrations/ subtree yet)                # ← envelope still has no home
```

**P3 #1 boundary memo §4.5 已決議**：envelope storage 走 `orchestrations/<stamp>/` four-part snapshot（與 P2 對稱）。本 memo 把那個決議的**精確 layout / writer 介面 / 失敗時行為**全部 nail down。

### 2.2 Compile Surface（純 reconstruct path、不認識 envelope）

`engine/task_scoped_compiler.compile_task` 當前是純函式：

```python
def compile_task(self, source_request: str, registry_ref: str | None = None) -> dict:
    constitution = self.build_task_constitution(source_request)
    capability_graph = self.build_capability_graph(constitution)
    candidate_workflow = self.build_candidate_workflow(constitution, capability_graph)
    # ... binder + unresolved_policy + compiled_workflow + plan
```

5 個 build step：
1. `build_task_constitution(source_request)` — SHA-1 + token matching 內部 reconstruct
2. `build_capability_graph(constitution)` — 從 constitution 推導
3. `build_candidate_workflow(constitution, graph)` — 拼 minimal workflow
4. `binder.bind_semantic_plan(...)` — capability → skill resolution
5. `apply_unresolved_policy(...)` + `build_bound_execution_phases_from_workflow(...)` — final compile + plan

**Step 1-2 是 envelope-driven 可短路的**：envelope 已含 `task_constitution` + `capability_graph` 兩個 nested artifact，根本不需要從 source_request reconstruct。**Step 3-5 不動**：candidate workflow / binding / policy 是 compile pipeline 的核心邏輯，envelope 不取代它們。

**Caller 盤點**：
- `engine/workflow_cli.py:cmd_compile_json` → `compile_task(request)` (cap workflow compile)
- `engine/workflow_cli.py:cmd_run_task_*` → `compile_task(...)` (cap workflow run-task)
- `engine/workflow_cli.py:cmd_constitution_json` → `build_task_constitution(request)`（不走完整 compile）

每一個 caller 都是「source_request → output」的純函式 contract。任何 envelope-driven 的改動**必須保留**這個 contract。

### 2.3 Bind Surface（compile_task 內呼叫，不直接讀 envelope）

`engine/runtime_binder.RuntimeBinder.bind_semantic_plan` 接的是 `semantic_plan`（從 candidate workflow 算出的），不是 envelope。它讀不到 envelope.compile_hints 的 `registry_preference` / `fallback_policy` 等指示。**P3 #1 boundary §4.3 決議**：binder 讀 envelope.compile_hints。實作 path：`compile_task` 把 envelope.compile_hints 翻成 binder 既有的 `registry_ref` / fallback policy，binder 介面不變。

### 2.4 Workflow YAML Surface（沒任何 step 用 supervisor_envelope_validation）

`grep supervisor_envelope_validation schemas/workflows/*.yaml` 為空。`scripts/cap-workflow.sh` 也沒呼叫該 capability。**P3 #4 commit (`d7e5358`) 已落 capability + executor，但只是 standalone**——沒被任何 workflow step 引用。P3 #5-c 才會 wire。

### 2.5 Legacy Task-Scoped Flow（與 envelope 並行的 SSOT）

`task_scoped_compiler.compile_task` 內部 reconstruct 出來的 `{task_constitution, capability_graph, ...}` dict 是「task-scoped 內部結果聚合」，**形狀與 envelope 不同**——前者是 compile 內部 working state、後者是 supervisor 對外 envelope。`schemas/supervisor-orchestration.schema.yaml` schema header 已明文指出兩者的差異（v0.22.0-rc1 commit `82ad424` schema landed time）。

兩個 SSOT 並行的後果：
- **producer 不一樣**：legacy flow 由 deterministic compiler 產（cap workflow compile 路徑），envelope 由 supervisor sub-agent 產（P3 producer 路徑）。
- **consumer 不一樣**：legacy compile output 直接餵 RuntimeBinder；envelope 經 P3 #4 validation gate 後落地，consumer 還沒接通。
- **內容大致相通**：envelope.task_constitution / capability_graph 的形狀**應該**等於 legacy compile 的 task_constitution / capability_graph（schema 同源），但實際 producer 不同所以 byte-level 不會 byte-equal（envelope 多 governance / failure_routing 等 envelope-only 欄位）。

P3 #5-b 要做的是**讓 compile_task 接受 envelope 作為 alternative input**，envelope 提供時走 envelope-driven path（短路 step 1-2），envelope 不提供時走 legacy reconstruct path（一字不改）。

## 3. The Real Problem in One Line

> **Envelope 已被驗證但未落地、compile/bind 仍走 legacy reconstruct、新舊 SSOT 並行卻沒切換策略——三件事彼此耦合，必須一次拍板邊界再分階段落地。**

P3 #5-a / 5-b / 5-c 的拆分本身已合理，本 memo 把每階段的**入口介面 / 失敗行為 / legacy fallback 規則**全部寫死。

## 4. Proposed Boundary（P3 #5 拍板對象）

### 4.1 Storage Layout（P3 #5-a 落地對象）

**Disk layout**（與 P2 `constitutions/project/<stamp>/` byte-for-byte 對稱）：

```text
~/.cap/projects/<project_id>/
└── orchestrations/
    └── <stamp>/                                    # one supervisor envelope per dir
        ├── envelope.json                           # full envelope (incl. nested task_constitution / capability_graph)
        ├── envelope.md                             # human-readable rendering (placeholder per §4.5 below)
        ├── validation.json                         # jsonschema verdict + drift report (envelope-only, nested validators not duplicated)
        └── source-prompt.txt                       # original user prompt (verbatim)
```

**Stamp 格式**：`YYYYMMDDTHHMMSSZ`（與 P2 / `persist-constitution.sh` / `engine/project_constitution_runner.py` 對齊；lexicographic sort = chronological order）。

**Filename 全部固定**（不 parameterise）：consumer 永遠讀同樣 4 個檔名，不需 glob。

**何時落地**（Q1 拍板對象）：
- 預設策略 = envelope **passing P3 #4 validation gate** 之後立刻寫四件套。
- Validation **失敗時也寫四件套**（仿 P2 Q2 = A 的 doctor 可觀測性裁示）：`envelope.json` 仍寫真實內容、`envelope.md` 寫 placeholder 標記 failed、`validation.json` `status: failed` 並含完整 errors / drift 列表、`source-prompt.txt` 仍寫原 prompt。如此 doctor / status 可以觀察「supervisor 產 invalid envelope」這件事，而不是 envelope 消失於無跡。

### 4.2 Storage Writer Interface（P3 #5-a 新模組）

**新增** `engine/orchestration_snapshot.py`（與 `engine/project_constitution_runner.py` 平行、純 helper module，不接 runtime hook）。

**Public surface**：

```python
@dataclass(frozen=True)
class OrchestrationSnapshotPaths:
    snapshot_dir: Path
    envelope_json: Path
    envelope_md: Path
    validation: Path
    source_prompt: Path

def compute_snapshot_dir(
    project_id: str,
    stamp: str,
    cap_home: Path,
) -> Path: ...

def write_snapshot(
    *,
    project_id: str,
    cap_home: Path,
    stamp: str,
    envelope_payload: dict,
    validation_report: dict,
    source_prompt: str,
) -> OrchestrationSnapshotPaths: ...
```

**Constraints**：
- Pure function — 唯一副作用是 `mkdir` + 寫 4 檔。
- **不**自己跑 jsonschema（呼叫者必須先用 `engine/supervisor_envelope.py` 驗過、把 validation 結果作為 `validation_report` 參數傳入）。Storage writer 不重複驗證，避免雙寫漂移。
- **不**自己處理 fence extraction（envelope_payload 必須是已解析的 dict）。
- **不**接到 runtime hook（runtime 在 P3 #5-c 才呼叫此 helper）。
- 本 commit 不寫 markdown 渲染細節：`envelope.md` 採 placeholder（仿 P2 `_render_placeholder_markdown`），P3 #7 docs 階段才升級。

### 4.3 Compile/Bind Transition（P3 #5-b 落地對象）

**改 `engine/task_scoped_compiler.compile_task` 簽章**為：

```python
def compile_task(
    self,
    source_request: str | None = None,
    *,
    envelope: dict | None = None,
    registry_ref: str | None = None,
) -> dict:
    ...
```

**Branching rule**：

| `envelope` | `source_request` | 行為 |
|---|---|---|
| `None` | `str` | **legacy reconstruct path**（現行行為，一字不改）：`build_task_constitution(source_request)` + `build_capability_graph(...)` 重做 |
| `dict` | ignored if both | **envelope-driven path**：直接讀 `envelope["task_constitution"]` + `envelope["capability_graph"]`，跳過 build_task_constitution / build_capability_graph 兩個 step |
| `None` | `None` | raise `ValueError("compile_task requires either source_request or envelope")` |

**Step 3-5（candidate workflow / binder / policy / compiled）** 對兩條 path 完全相同——它們只讀 task_constitution / capability_graph dict，不關心來源。

**`compile_hints` 流入 binder**：envelope-driven path 下，`envelope["compile_hints"]` 透過 `registry_ref` + 額外 binder kwargs 傳給 `bind_semantic_plan`。具體 mapping 見 §5。

**`build_task_constitution` / `build_capability_graph` 不動**：legacy caller（含 P3 #5 之外的 future work）仍可獨立呼叫；envelope-driven path 不在這兩個函式內 short-circuit，而是在 `compile_task` 入口分流。

### 4.4 Legacy Task-Scoped Flow Compatibility

**所有現行 caller 行為不變**：

| Caller | 走哪條 path | 變動 |
|---|---|---|
| `engine/workflow_cli.py:cmd_compile_json` (`cap workflow compile`) | legacy reconstruct (envelope=None) | 0（caller 不傳 envelope）|
| `engine/workflow_cli.py:cmd_run_task_*` (`cap workflow run-task`) | legacy reconstruct | 0 |
| `engine/workflow_cli.py:cmd_constitution_json` (`cap task constitution` / deprecated `cap workflow constitution`) | 不經過 `compile_task`（直接呼 `build_task_constitution`） | 0 |
| Future envelope-driven caller (P3 #5-c workflow YAML) | envelope-driven (envelope=full dict) | 新增 |

**Deprecation strategy**：
- legacy reconstruct path **永久保留**，不打 deprecation。多處 caller 已使用，且 deterministic compiler 本身有獨立價值（不需要 supervisor sub-agent 也能跑）。
- envelope-driven path 是**新增能力**，不取代 legacy。
- 文件對照表（P3 #7）會明示「legacy = no supervisor envelope，envelope-driven = supervisor envelope SSOT」的選擇條件。

### 4.5 Workflow YAML Wiring（P3 #5-c 落地對象）

**P3 #5-c 邊界（本 memo 不細排，留實作前再細化）**：
- 不動既有 per-stage workflow YAML（`project-spec-pipeline.yaml` / `project-implementation-pipeline.yaml` / `project-qa-pipeline.yaml`）。它們仍走 task constitution + handoff ticket 老路。
- 新增 envelope-aware step **作為可選擴展**，初期可能只接到 `project-constitution.yaml` workflow（把 supervisor envelope 作為 project constitution 的 wrapper）或新建 dedicated supervisor workflow。
- 具體 wiring 由 P3 #5-c 實作前再開一個 mini-memo（或在 P3 #5-c commit 內 inline 描述），不在本 memo 鎖死。

## 5. Compile/Bind Transition Mapping Table

| 來源 | Legacy reconstruct path | Envelope-driven path |
|---|---|---|
| `task_constitution` | `build_task_constitution(source_request)` SHA-1 + token matching | `envelope["task_constitution"]` 直接讀 |
| `capability_graph` | `build_capability_graph(constitution)` 從 constitution 推 | `envelope["capability_graph"]` 直接讀 |
| `registry_ref` | caller arg `registry_ref` | caller arg `registry_ref`（envelope.compile_hints.registry_preference 可作為**預設值**，caller arg 仍 override） |
| `fallback_policy` | binder default (`halt`) | `envelope["compile_hints"]["fallback_policy"]`（如有） |
| `preferred_cli` | n/a | `envelope["compile_hints"]["preferred_cli"]`（如有） |
| `attach_inputs` | n/a | `envelope["compile_hints"]["attach_inputs"]`（如有；caller 可決定是否實際 attach） |
| `notes` | n/a | `envelope["compile_hints"]["notes"]`（純標註，traceability 用） |
| `governance` | n/a (workflow YAML 自帶) | `envelope["governance"]`（傳給 RuntimeBinder 或 emit ticket 階段） |
| `failure_routing` | n/a | `envelope["failure_routing"]`（傳給 P3 #6 dispatcher） |

## 6. Implementation Order for P3 #5

依本 memo 邊界推導出的拆分：

| # | 子任務 | 變動範圍 | 阻塞下一步？ |
|---|---|---|---|
| **P3 #5 (this memo)** | boundary memo | docs only | ✓（5-a / 5-b / 5-c 的錨）|
| P3 #5-a | `engine/orchestration_snapshot.py` 純 storage writer + smoke | engine 新模組 + tests/scripts | 是（5-b 需要 storage 落地後才能用 envelope-driven path 觀察結果）|
| P3 #5-b | `task_scoped_compiler.compile_task` 加 `envelope` 參數 + branching；binder 接 compile_hints | engine/task_scoped_compiler.py + 可能 engine/runtime_binder.py + smoke | 是（5-c 需要 envelope-driven compile 已可用）|
| P3 #5-c | workflow YAML 引用 `supervisor_envelope_validation` + 啟用 envelope-driven flow | schemas/workflows/*.yaml + scripts/cap-workflow.sh | 否（後續 P3 #6 / #7 可獨立進行）|

每個 sub-commit 都帶獨立 smoke、各自接入 `smoke-per-stage.sh`，全部 deterministic（無 AI / 無 network）。

## 7. Open Questions（need user decision）

1. **Validation 失敗時 storage writer 是否仍寫四件套？**
   - 選 A：仿 P2 Q2 = A — 寫四件套，`validation.json: status: failed` 含完整 errors，doctor / status 可觀察 partial state。
   - 選 B：失敗時 abort，不寫任何檔案；envelope 消失於無跡。
   - 選 C：失敗時只寫 `validation.json`，不寫其他三檔（部分落地）。
   - **建議 A**：與 P2 對稱、給 doctor 觀察 supervisor 失誤的能力；C 會讓 storage layout 不對稱（四件套有時三件）。

2. **`compile_task` 的 envelope 參數要不要接受 part envelope（只填 task_constitution + capability_graph，不填其他）？**
   - 選 A：必須是完整 envelope（11 個 envelope-level required 全填）；compile_task 不接受 partial。
   - 選 B：接受 partial（minimum: task_constitution + capability_graph）；其他欄位缺失走 binder default。
   - 選 C：接受 partial 但 emit warning。
   - **建議 A**：envelope 是 single SSOT，partial envelope 違反「envelope 是 supervisor 對單一 prompt 的整體決策」原則；caller 若只有 task_constitution + capability_graph 不需要 envelope，直接用 legacy reconstruct path（不傳 envelope）。

3. **legacy reconstruct path 的 deprecation timeline？**
   - 選 A：永久保留，不打 deprecation（envelope-driven 是新增能力、不取代 legacy）。
   - 選 B：P4 SupervisorOrchestrator 完成後 deprecate（legacy 是過渡期 fallback）。
   - 選 C：P3 #5-c 完成立即 deprecate（envelope 是新 SSOT）。
   - **建議 A**：legacy compile_task 已被多處 caller 使用（cap workflow compile / run-task），`build_task_constitution` 也是純函式有獨立價值；deprecate 會破壞「不依賴 AI sub-agent 也能 compile」的能力，這個能力對 deterministic CI / 測試環境是寶貴的。envelope-driven 是**升級路徑**而非**取代路徑**。

請使用者就這 3 點裁示後再進 P3 #5-a。

## 8. Cross-References

- 上層邊界：`docs/cap/SUPERVISOR-ORCHESTRATION-BOUNDARY.md`（P3 #1，5-surface 分流 SSOT）。
- 對稱模式：`docs/cap/CONSTITUTION-BOUNDARY.md`（P2，four-part snapshot 與 backup-on-overwrite 模板來源）。
- Schema 契約：`schemas/supervisor-orchestration.schema.yaml`（P0 #4 + P3 #2 含 failure_routing required）。
- Producer 規範：`agent-skills/01-supervisor-agent.md` §3.8（envelope emission rules）。
- Producer-side helper：`engine/supervisor_envelope.py`（P3 #3 commit `4bf13a0`，extract / validate / drift pure functions）。
- Runtime gate：`scripts/workflows/validate-supervisor-envelope.sh` 與 `supervisor_envelope_validation` capability（P3 #4 commit `d7e5358`）。
- Compile/bind 改動入口：`engine/task_scoped_compiler.compile_task` (line 265) 與 `engine/runtime_binder.RuntimeBinder.bind_semantic_plan`（P3 #5-b 不動 binder 簽章，只動 compile_task 入口分流 + compile_hints 翻譯）。
- Storage 路徑契約：`policies/cap-storage-metadata.md` §1（runtime stores under `~/.cap/projects/<id>/`）。
- 政策依據：`policies/constitution-driven-execution.md` §1.3（Mode C conductor binding — supervisor 是 envelope producer）。
- P3 brief：使用者於 v0.22.0-rc3 closeout 後的 P3 任務清單，§5 拆 5-a / 5-b / 5-c。
