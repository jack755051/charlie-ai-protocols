# CAP Replay Contract Policy (v1)

> 本文件定義 `cap replay` 的行為邊界、verdict 語意與 consumer 義務。
> SSOT：`policies/replay-contract.md`（本檔）。
> Schema：[`schemas/replay-verdict.schema.yaml`](../schemas/replay-verdict.schema.yaml)。
> Design rationale：[`docs/cap/REPLAY-CONTRACT-DESIGN.md`](../docs/cap/REPLAY-CONTRACT-DESIGN.md)。
> User guide：[`docs/cap/REPLAY-USER-GUIDE.md`](../docs/cap/REPLAY-USER-GUIDE.md)。

## 1. 範圍與定位

CAP Replay Contract v1（H1）只回答一個問題：**「給定一個歷史 `run_id`，該 run 對應的 builtin agent-skills baseline 與當前 baseline 的差異是否影響 replay 資格？」**

本契約**不**涵蓋：

- 真正重跑 workflow（full replay execution）— 留給 H4+。
- Project layer `.cap/skills.yaml` 的 drift 判斷 — 留給 H2。
- Workflow YAML drift / capability schema drift / constitution drift — 留給 H2 / H3。
- 跨 run 聚合（一次驗證多個 run）— 後續批次。

## 2. Verdict 5-state Enum（normative）

| Verdict | 觸發條件 | Consumer 行為建議 |
|---|---|---|
| `replayable` | stored baseline 等於 current baseline（dir_hash 一致 + 所有 prompt_files 對齊） | 可直接 replay（後續 H4+ 提供） |
| `drifted_compatible` | dir_hash 不一致，但該 run 實際使用的 prompt_files 全部對齊 | 仍可 replay；變動的檔案不影響原行為 |
| `drifted_incompatible` | 該 run 使用的某個 prompt_file 內容變動或被刪除 | **不可** replay 為原行為；必須 checkout 對應 commit 或放棄 replay |
| `unverifiable` | stored envelope 沒有 `agent_skills_baseline`（pre-A0 #4 run） | 無法判斷；consumer 自行決定保守處置（預設仍 pass） |
| `not_found` | run_id 對應的 run dir 或 `agent-sessions.json` 缺失 | 該 run 已被 prune 或 run_id 錯誤；不可 replay |

## 3. Drift 偵測範圍（v1）

### 3.1 主動判斷（影響 verdict）

| 來源 | 偵測方式 |
|---|---|
| `agent-skills/` builtin baseline `dir_hash` | aggregate hash 比對 |
| 該 run 使用的 prompt_files 的 per-file hash | per-file hash 比對 |
| 該 run 使用的 prompt_files 在 current baseline 是否仍存在 | dict key 存在性檢查 |

### 3.2 Soft signal（記錄但不影響 verdict）

| 來源 | 為什麼不直接降 verdict |
|---|---|
| `cap_version` 變動 | release tag 變動但 `agent-skills/` 沒變，replay 行為仍一致；硬降會造成噪音 |
| `git_commit` 變動 | 同上，可能只是 release commit |
| `git_dirty` 切換 | 不可靠的訊號（暫存檔可能不影響 prompt） |

### 3.3 Reserved-null forward contract

| 欄位 | v1 行為 | 後續 batch |
|---|---|---|
| `drift_details.project_skill_diff` | 永遠為 `null` | H2 將以 object 填值 |

## 4. CLI 介面契約

### 4.1 入口

`cap replay verify <run_id_or_run_dir> [--json] [--no-write]`

- 接受 bare run_id（在 `<workflow_report_dir>/*/<run_id>` 下 glob）或絕對 run_dir 路徑（bypass glob）。
- 預設寫 `<run_dir>/replay-verdict.json` 與 `<run_dir>/snapshots/agent-skills.json`；`--no-write` 為 read-only。
- `--json` 印 raw envelope 到 stdout；無此 flag 印人類可讀單行摘要。

### 4.2 Exit code 規範

| Verdict | Exit code | 含義 |
|---|---|---|
| `replayable` | 0 | OK |
| `drifted_compatible` | 0 | warn-but-pass，CI 可進 |
| `unverifiable` | 0 | 不主動視為失敗（H2 可能加 `--strict-unverifiable` 升為 4） |
| `drifted_incompatible` | 4 | block — 對齊 P8 governance gate non-zero pattern |
| `not_found` | 2 | run 不存在 |
| internal error | 1 | 其他錯誤 |

## 5. 持久化規則

### 5.1 `<run_dir>/replay-verdict.json`

- **唯一寫入者**：`cap replay verify` / `engine/replay_verifier.py`。
- **覆寫策略**：覆寫舊檔；verdict 是純函式，不需保留歷史（design memo §5）。
- **Idempotent**：當前 verdict 與 cached 一致 → 不寫（避免無謂 IO）。

### 5.2 `<run_dir>/snapshots/agent-skills.json`

- **唯一寫入者**：`cap replay verify` / `engine/replay_verifier.py`。
- **內容**：與 `agent-sessions.json` envelope 的 `agent_skills_baseline` 欄位 byte-for-byte 一致。
- **角色**：cache / convenience copy。envelope 是 SSOT，mirror 是投影；衝突時以 envelope 為準。
- **Idempotent**：同上。
- **Subdir 結構**：`snapshots/` 為 H2 / H3 預留 `project-skills.yaml.json` / `workflows/<id>.yaml.json` / `capabilities.yaml.json` / `constitution.yaml.json`。

### 5.3 不允許

- ❌ Consumer 直接編輯 `replay-verdict.json` 或 `snapshots/agent-skills.json`。
- ❌ 用 `replay-verdict.json` 取代 `agent-sessions.json` 作為 baseline 來源（envelope 是 SSOT）。
- ❌ 在 verdict 為 `drifted_incompatible` 時靜默 replay（必須先讓使用者意識到 drift）。

## 6. Backward Compatibility

- **A0 #4 之前的 run**（envelope 沒有 `agent_skills_baseline`）→ verdict 永遠是 `unverifiable`，不嘗試猜測。
- **未掛 H1 之前的 run**（無 `replay-verdict.json` / `snapshots/`）→ 第一次跑 `cap replay verify` 會 lazy 建立。
- **Schema 升版**：`schema_version: 1`；breaking change 才 bump。

## 7. Consumer 義務

凡是接 `replay-verdict.json` 或呼叫 `cap replay verify` 的下游 pipeline（如 promote、archive lifecycle、CI gate）必須：

1. 解析 `verdict` 字串 enum；不要依字面 reason 判斷。
2. 對 `drifted_incompatible` 採行 block 行為（exit non-zero、不繼續 promote、不歸檔為 replayable）。
3. 對 `unverifiable` 不假設「pass」或「fail」；應在 consumer side 自有政策。
4. 不修改 `replay-verdict.json`；若需附加自己的判讀，另寫 sibling 檔。

## 8. 與 A0 #4 baseline snapshot 的關係

| 角色 | A0 #4 | H1 |
|---|---|---|
| **記錄** baseline 是什麼 | ✓（`agent-sessions.json` envelope） | — |
| **比對** baseline 是否漂移 | ✗ | ✓（`replay-verdict.json`） |
| **獨立 per-run snapshot 檔** | deferred | ✓（`snapshots/agent-skills.json`） |
| **CLI 入口** | — | ✓（`cap replay verify`） |

H1 直接消費 A0 #4 寫入的 envelope baseline；不重新計算「該 run 當時的 baseline 是什麼」。

## 9. 後續契約展開（Forward Look）

- **H2**：`drift_details.project_skill_diff` 由 reserved-null 升為 object；新增 `snapshots/project-skills.yaml.json` 與 `snapshots/workflows/<id>.yaml.json`；可能新增 `--strict-unverifiable` 旗標。
- **H3**：capability schema / constitution drift 加入 verdict 計算。
- **H4+**：full replay execution（真重跑）；可能引入 `cap replay run <run_id>` 與 pinned baseline 模式。
