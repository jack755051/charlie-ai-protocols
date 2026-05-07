# H1 Replay Contract — Design Memo (accepted baseline)

> 本文件是 H1 #2-#5 的設計 baseline。`H1 #1`（即本 memo）為 doc-only，記錄 H1 整段在 commit 前的裁定；後續 H1 #2-#5 實作必須 cross-reference 本 memo 對應段落。
>
> 範圍：給定一個歷史 `run_id`，回答「這個 run 對應的 builtin baseline 與當前 baseline 的差異是否影響 replay 資格」。
> 非範圍：真的重跑 workflow（full replay execution）、project layer skill drift 判斷、workflow YAML drift 判斷 — 留給 H2 / H3。

## 1. 目標（Goals）

1. **可機器讀的 verdict envelope**：自動化 pipeline（如 promote、archive lifecycle、CI gate）能解析 verdict 決定下一步。
2. **Verdict 是純函式**：給定相同的「stored baseline + current baseline」，永遠產出相同 verdict；沒有副作用、沒有時間相關決策。
3. **可審計**：verdict envelope 帶足夠的 drift detail，使用者看 verdict 就知道為什麼是這個結果，不需另開 diff 工具。
4. **不破既有**：A0 #4 之前的 run（`agent_skills_baseline = null`）一律 `unverifiable`，verifier 不嘗試猜測。
5. **守住 v1 範圍**：H1 v1 只判 builtin `agent-skills/` 的 drift；project `.cap/skills.yaml` / workflow YAML / capability schema 的 drift 留給 H2/H3。

## 2. Verdict 5-state Enum（Q1 = A）

| Verdict | 條件 | 含義 |
|---|---|---|
| `replayable` | stored baseline 完全等於 current baseline（dir_hash 一致 + 所有 prompt_files 對齊） | 該 run 對應的 builtin baseline 沒漂移，可放心 replay |
| `drifted_compatible` | dir_hash 不一致，**但**該 run 實際使用的 prompt_files（從 `agent-sessions.json` 的 `sessions[].prompt_file` 抽出來）的 per-file hash 全部對齊 | builtin 整體有變動，但變動沒踩到該 run 用過的 prompt — 該 run 仍可 replay |
| `drifted_incompatible` | 該 run 實際使用的某個 prompt_file 的 per-file hash 不一致，**或**舊 baseline 中存在的某個 prompt_file 在 current baseline 中已被刪除 | 該 run 的 prompt 已變動，replay 不會還原為當時行為 |
| `unverifiable` | stored envelope 沒有 `agent_skills_baseline`（pre-A0 #4 run）；或 `cap_version` 為 null + `git_commit` 為 null 表示無法定錨 | 沒有足夠資訊判斷 — 不主動猜，標 unverifiable |
| `not_found` | `run_id` 對應的 `<run_dir>` 不存在或 `agent-sessions.json` 缺失 | run 已被 prune 或路徑錯誤 |

### 2.1 為什麼分 `drifted_compatible` 和 `drifted_incompatible`

- builtin 修改一個 strategy file（如 `strategies/lighthouse-audit.md`）會改 dir_hash，但如果該 run 沒用到這個 strategy，replay 行為不變。粗暴標所有 dir_hash 不一致為 `drifted` 會讓 verdict 噪音化。
- 區分 prompt-level drift（致命）vs 整體 drift（無關緊要）才能讓使用者把注意力放對地方。

### 2.2 哪些 prompt_files 算「該 run 實際使用」

從 `agent-sessions.json` 的 `sessions[].prompt_file` 欄位抽 distinct set。這個欄位由 cap-workflow-exec.sh 在每個 step 的 `upsert-session` 時寫入，覆蓋率 = 該 run 實際 spawn 的 sessions。Shell-only steps `prompt_file = null`，自動排除。

> **邊界**：`prompt_file` 通常是 relative path（`agent-skills/04-frontend-agent.md`）；verifier 必須把它與 baseline `prompt_files` 字典的 key（`04-frontend-agent.md`，相對於 `agent-skills/` 目錄）做正規化比對 — 拿掉前綴 `agent-skills/`，再以 strategies 子目錄為相對路徑前綴比對。

## 3. Drift Detection 範圍（Q3 = A，收緊版）

| 來源 | H1 v1 是否判斷 | 後續 batch |
|---|---|---|
| `agent-skills/` builtin baseline（dir_hash + per-file hashes） | ✓ | — |
| `<project_root>/.cap/skills.yaml` project layer override | ✗（schema 預留 `drift_details.project_skill_diff = null` 欄位作為 forward contract） | H2 |
| Workflow YAML 內容（該 run 用過的 workflow 是否被改） | ✗ | H2 |
| `schemas/capabilities.yaml` capability contract | ✗ | H3 |
| `<project_root>/.cap/constitution.yaml` allowed_capabilities | ✗ | H3 |
| `cap_version` mismatch（runtime 版本變動） | ✓ as **soft signal**：寫進 verdict envelope 的 `baseline_observed.cap_version` vs `baseline_current.cap_version`，但**不**主動降級 verdict（`drifted_*` 仍以 hash 為準） | — |
| `git_commit` mismatch | ✓ as soft signal，同上 | — |

### 3.1 為什麼 `cap_version` / `git_commit` 不直接降 verdict

- cap_version 變動但 `agent-skills/` 沒變，replay 行為仍一致。把 cap_version drift 當 verdict-changing factor 會造成 noise（每次 release tag 都會把所有舊 run 標 drifted）。
- git_commit 同理：可能只是 release commit 而沒實際改 prompt。
- 這兩個欄位 envelope 仍記錄，consumer（如 promote pipeline）若有自己的政策可基於這兩個欄位再升級嚴重度，但 verifier 本身不做。

### 3.2 為什麼 H1 不判 project skill drift

使用者明確指示（Q3 收緊）：**避免 H1 過早耦合 source resolver / registry merge**。

- 判 project skill drift 需要：
  1. 紀錄該 run 用到哪些 project-layer skills（要 enrich `agent-sessions.json` 的 `skill_source` 資訊）
  2. 比對 stored vs current 的 project `.cap/skills.yaml` 內容
  3. 處理 mask / replace 變動的語意（disabled 變 enabled、replaces target 改了）
- 這一連串會把 verifier 的責任邊界從「baseline」擴張到「整個 source resolver 的當下版本對 stored 版本的 diff」，scope 過大。
- H1 schema 預留 `drift_details.project_skill_diff = null` 欄位作為 forward contract，H2 接手時不需 schema bump。

## 4. Per-Run Snapshot 檔案佈局（Q2 = B）

### 4.1 Snapshot subdir 結構

每個 run dir 下新增 `snapshots/` 子目錄：

```
~/.cap/projects/<id>/reports/workflows/<workflow_id>/<run_id>/
├── agent-sessions.json
├── runtime-state.json
├── workflow.log
├── ...
└── snapshots/
    └── agent-skills.json    ← H1 #4 寫入
```

`snapshots/` 為未來 H2 / H3 預留：
- `snapshots/project-skills.yaml.json`（H2）— project layer skill registry 內容快照
- `snapshots/workflows/<workflow_id>.yaml.json`（H2）— workflow YAML 內容快照
- `snapshots/capabilities.yaml.json`（H3）— capability contract 快照
- `snapshots/constitution.yaml.json`（H3）— constitution 快照

> **為什麼用 subdir 而不是 flat file（`agent-skills-snapshot.json`）**：H2 / H3 一定要加 snapshot，flat naming 會讓 run dir 多一堆 `*-snapshot.json` 檔。從 H1 開始就 subdir 結構，後續無需 rename / migrate。

### 4.2 `snapshots/agent-skills.json` 內容

與 `agent-sessions.json` envelope 的 `agent_skills_baseline` 欄位 **byte-for-byte 一致**。為什麼還要獨立檔？

- envelope 內的欄位需要解析整個 ledger 才能讀到；獨立檔讓外部工具（如 IDE plugin、CI dashboard）可直接 stat / read 一個 small JSON，不必先 parse hundreds of sessions。
- envelope 是 first-class data；snapshot 檔是 cache / convenience copy。**唯一寫入者**：`cap replay verify` 第一次跑時 lazy-write；後續調用如果發現檔已存在且 envelope 內容一致就不重寫。
- 衝突來源：如果使用者手動改 envelope（不該發生但 defensive），snapshot 檔可能與 envelope 不一致。Verifier 永遠以 envelope 為 SSOT，snapshot 檔只是投影。

## 5. Verdict 持久化（Q4 = B）

每次 `cap replay verify <run_id>` 寫 `<run_dir>/replay-verdict.json`，覆寫舊檔。

- **為什麼覆寫不是版號**：verdict 是純函式，相同 input 永遠相同 output；不需要保留歷史。
- **為什麼寫 disk**：consumer（如 promote pipeline）可直接讀 cached verdict，避免重算（cap_version + git invocation + per-file hash 的 cost 雖然小但 hot path 上累積）。
- **覆寫前提**：verifier 重算後的 verdict 與 cached 不一致 → 覆寫；一致 → no-op（避免無謂 IO）。
- **檔案 schema**：`schemas/replay-verdict.schema.yaml`（H1 #2 落地）。

### 5.1 與 `snapshots/agent-skills.json` 的關係

- `snapshots/agent-skills.json` = **「該 run 觀察到的 baseline」** 的快照（envelope mirror）。
- `replay-verdict.json` = **「該 run 與當前 baseline 的比對結果」** 的快照。
- 兩者並存：snapshot 是 input，verdict 是 output。重算 verdict 不會動 snapshot；snapshot 是 immutable（除非 envelope drift，這時 verifier 重新 mirror）。

## 6. 介面契約

### 6.1 `engine/replay_verifier.py`

純函式 + argparse CLI（與 `engine/agent_skills_snapshot.py` 同模式）。

```python
def verify_run(
    run_dir: Path,
    *,
    current_snapshot: dict | None = None,
    agent_skills_dir: Path | None = None,
) -> dict:
    """Return a replay-verdict envelope conforming to schemas/replay-verdict.schema.yaml.
    
    `current_snapshot` defaults to compute_snapshot() result;
    callable callers can inject a fixed snapshot for deterministic
    tests.
    """
```

CLI subcommand：

| Subcommand | 行為 |
|---|---|
| `python engine/replay_verifier.py verify <run_dir>` | 計算 verdict 並印 JSON 到 stdout（不寫 disk） |
| `python engine/replay_verifier.py verify <run_dir> --write` | 計算 verdict 並寫 `<run_dir>/replay-verdict.json` 與 `<run_dir>/snapshots/agent-skills.json`（兩者 idempotent） |

### 6.2 `cap replay verify <run_id>`

Shell wrapper（H1 #4）：

- 解析 `<run_id>` → `<run_dir>`（用既有的 cap-paths.sh 慣例）。
- 呼叫 `replay_verifier.py verify <run_dir> --write`。
- 印一行人類可讀摘要 + 以 verdict 對應的 exit code 收尾：
  - `replayable` → exit 0
  - `drifted_compatible` → exit 0（warn-but-pass，CI 仍可進）
  - `drifted_incompatible` → exit 4（block — 沿用 P8 governance gate non-zero pattern）
  - `unverifiable` → exit 0（無法判斷不視為失敗；caller 可加 `--strict-unverifiable` 升為 exit 4，留 H2 deferred）
  - `not_found` → exit 2

## 7. Schema Skeleton（H1 #2 落地）

```yaml
# schemas/replay-verdict.schema.yaml
schema_version: 1
title: CAP Replay Verdict
description: Output of `cap replay verify <run_id>`; pure-function comparison of stored baseline against current baseline.

required:
  - schema_version
  - run_id
  - verified_at
  - verdict
  - baseline_observed
  - baseline_current
  - drift_details

properties:
  schema_version: {type: integer, enum: [1]}
  run_id: {type: string}
  verified_at: {type: string}  # ISO-8601 UTC
  verdict:
    type: string
    enum: [replayable, drifted_compatible, drifted_incompatible, unverifiable, not_found]
  reason: {type: string}  # human-readable verdict explanation
  baseline_observed:  # 從 agent-sessions.json envelope 讀
    type: [object, "null"]
    # null → unverifiable
    properties:
      cap_version: {type: [string, "null"]}
      git_commit: {type: [string, "null"]}
      git_dirty: {type: boolean}
      dir_hash: {type: string}
      file_count: {type: integer}
  baseline_current:  # verifier 跑當下的 compute_summary 結果
    type: object
    properties:
      cap_version: {type: [string, "null"]}
      git_commit: {type: [string, "null"]}
      git_dirty: {type: boolean}
      dir_hash: {type: string}
      file_count: {type: integer}
  drift_details:
    type: object
    required:
      - prompt_files_used
      - prompt_files_changed
      - prompt_files_removed
      - dir_hash_match
      - cap_version_match
      - git_commit_match
      - project_skill_diff
    properties:
      prompt_files_used:
        type: array
        items: {type: string}
        description: 該 run 實際使用的 prompt_files（從 agent-sessions.json 抽出 distinct set）
      prompt_files_changed:
        type: array
        items: {type: string}
        description: 在 prompt_files_used 中、stored 與 current 的 per-file hash 不一致
      prompt_files_removed:
        type: array
        items: {type: string}
        description: 在 prompt_files_used 中、current baseline 缺失的檔
      dir_hash_match: {type: boolean}
      cap_version_match: {type: boolean}
      git_commit_match: {type: boolean}
      project_skill_diff:
        type: [object, "null"]
        description: |
          H1 v1 reserved-null. H2 will populate with project layer skill drift
          detail; H1 verifier always emits null here. Forward contract field
          so consumers can rely on its presence at the schema level.
```

## 8. Deferred Items（明確列出、避免 scope creep）

| 項目 | Defer 給 |
|---|---|
| Project layer skill drift 判斷 | H2 |
| Workflow YAML drift 判斷 | H2 |
| Capability schema drift 判斷 | H3 |
| Constitution drift 判斷 | H3 |
| Full replay execution（真重跑） | 後續 H4+ batch |
| `cap replay diff` 顯示 file-level diff | 後續 |
| `cap replay status` 列出所有 run 的 verdict | 後續 |
| `--strict-unverifiable` 旗標把 unverifiable 升為 exit 4 | H2 |
| Cross-run verdict aggregation（一次驗證多個 run） | 後續 |

## 9. Acceptance Checklist（H1 整段）

- [ ] **H1 #1** — 本 memo（doc-only）作為 H1 #2-#5 baseline。
- [ ] **H1 #2** — `schemas/replay-verdict.schema.yaml` 落地；fixture-based jsonschema test 全綠。
- [ ] **H1 #3** — `engine/replay_verifier.py` + 純函式 unit test + CLI test。
- [ ] **H1 #4** — `scripts/cap-replay.sh` + `cap replay verify` 在 `scripts/cap-entry.sh` 註冊；端到端 e2e 寫 snapshot + verdict 並驗 exit code。
- [ ] **H1 #5** — `policies/replay-contract.md` SSOT、`docs/cap/REPLAY-USER-GUIDE.md` user guide、`docs/cap/H1-CLOSEOUT.md`、TODOLIST 加 H1 章節。

## 10. 實作順序（Implementation Sequencing）

對齊使用者的 commit-granularity rule（doc → contract → runtime → harness）：

1. **H1 #1**（commit）— 本 memo doc-only。
2. **H1 #2**（commit）— schema + schema test。
3. **H1 #3**（commit）— `engine/replay_verifier.py` + Python-side test。
4. **H1 #4**（commit）— `cap replay` CLI + cap-entry registration + per-run snapshot file producer + e2e test。
5. **H1 #5**（commit）— policy / user guide / closeout doc + TODOLIST 章節。

每個 sub-item 一個 commit，每個都帶 focused test 或 doc-only 變動，全綠後 push。

## 11. Design Decisions Locked

- **Verdict enum**：5 態（Q1 = A）。
- **Snapshot subdir**：`snapshots/` 子目錄而非 flat file（Q2 = B）。
- **Drift scope v1**：只 builtin agent-skills；project skill 留 schema 預留欄位（Q3 = A 收緊）。
- **Verdict 持久化**：寫 `<run_dir>/replay-verdict.json` 並覆寫（Q4 = B）。
- **`cap_version` / `git_commit` mismatch 不降 verdict**：只當 soft signal 記錄；avoid release-tag 噪音。
- **prompt_file path normalization**：拿掉 `agent-skills/` 前綴後與 baseline `prompt_files` dict key 比對；strategies 子目錄保留 relative。
- **Snapshot 檔 vs envelope SSOT**：envelope 是 SSOT，snapshot 檔是投影；衝突時以 envelope 為準。
