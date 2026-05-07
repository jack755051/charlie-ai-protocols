# Replay Verification User Guide

> 使用者導向：**怎麼判斷一個舊 run 還能不能 replay？**
> Normative SSOT：[`policies/replay-contract.md`](../../policies/replay-contract.md)、[`schemas/replay-verdict.schema.yaml`](../../schemas/replay-verdict.schema.yaml)。
> 設計理由：[`docs/cap/REPLAY-CONTRACT-DESIGN.md`](REPLAY-CONTRACT-DESIGN.md)。

## TL;DR

```bash
cap replay verify <run_id>
```

對某個 run 跑一次驗證，會印出 verdict 並把結果寫到：
- `<run_dir>/replay-verdict.json` — 結構化 verdict envelope
- `<run_dir>/snapshots/agent-skills.json` — 該 run 觀察到的 baseline 快照

## 1. 五個 Verdict 是什麼意思

| Verdict | 含義 | 你該做什麼 |
|---|---|---|
| `replayable` | builtin baseline 沒漂移；該 run 可放心重放 | 沒事，繼續 |
| `drifted_compatible` | builtin 變了但變動的檔案沒影響該 run | 可放心重放，**警示** dir_hash 不一致 |
| `drifted_incompatible` | 該 run 用過的 prompt 已經被改了或刪了 | **不可** replay 為原行為；要重放需 `git checkout <stored.git_commit>` |
| `unverifiable` | run pre-dates A0 #4，沒有 baseline 可比 | 自行政策；建議警示而不阻擋 |
| `not_found` | run 不存在或已被 prune | run_id 拼錯，或 archive lifecycle 已清掉 |

## 2. 場景 1：日常驗證（最常見）

剛跑完一個重要 workflow，過幾天想再回頭重跑驗證行為一致：

```bash
$ cap replay verify run_20260507120304_aabbccdd
cap replay: replayable — /Users/.../.cap/projects/myproj/reports/workflows/spec-pipeline/run_20260507120304_aabbccdd
  reason: stored baseline matches current baseline byte-for-byte
  verdict file: /Users/.../run_20260507120304_aabbccdd/replay-verdict.json
  snapshot mirror: /Users/.../run_20260507120304_aabbccdd/snapshots/agent-skills.json
```

`exit 0` → 該 run 對應的 builtin 沒變動。

## 3. 場景 2：CAP 升級後的 drift 檢查

升 cap-protocols 到新版本後，想知道哪些舊 run 還能 replay：

```bash
# 對每個 run 跑驗證，收集 verdict
for run in ~/.cap/projects/myproj/reports/workflows/*/run_*/; do
  run_id="$(basename "$run")"
  cap replay verify "$run_id" --json --no-write \
    | jq -r --arg id "$run_id" '"\($id) \(.verdict)"'
done
```

預期看到：
```
run_20260507120304_aabbccdd replayable
run_20260506093020_eeff0011 drifted_compatible
run_20260505180059_bbcc2233 drifted_incompatible
```

## 4. 場景 3：CI gate 接 replay 驗證

在 CI pipeline 把 `cap replay verify` 串進去，當 verdict 為 `drifted_incompatible` 直接 fail：

```yaml
- name: Verify replay readiness for production runs
  run: |
    cap replay verify "${{ env.LAST_PROD_RUN_ID }}"
    # exit code 4 → drifted_incompatible 自動 fail CI
```

Exit code mapping（也可寫進 `policies/replay-contract.md` §4.2）：

| Verdict | Exit code |
|---|---|
| `replayable` / `drifted_compatible` / `unverifiable` | 0 |
| `drifted_incompatible` | 4（block） |
| `not_found` | 2 |
| internal error | 1 |

## 5. 場景 4：用 verdict envelope 做更細的判斷

`replay-verdict.json` 帶 `drift_details` 欄位，可細看哪些檔案變了：

```bash
$ cat run_xxx/replay-verdict.json | jq '.drift_details'
{
  "prompt_files_used": [
    "01-supervisor-agent.md",
    "04-frontend-agent.md",
    "07-qa-agent.md"
  ],
  "prompt_files_changed": [
    "04-frontend-agent.md"
  ],
  "prompt_files_removed": [],
  "dir_hash_match": false,
  "cap_version_match": true,
  "git_commit_match": false,
  "project_skill_diff": null
}
```

這個例子顯示：該 run 用過 3 個 prompt，其中 `04-frontend-agent.md` 內容被改過。`project_skill_diff: null` 是 v1 reserved-null forward contract（H2 才會填值）。

## 6. 為什麼 `cap_version` 變了還是 replayable？

cap-protocols 的 release tag 變動本身不一定影響 prompt 內容。verifier 把 `cap_version` mismatch 當 **soft signal** 記錄但不直接降 verdict — 否則每次 release 都會把所有舊 run 標 drifted，治理上無意義。

如果你的政策需要把 cap_version 變動視為 drift，自行讀 `replay-verdict.json` 的 `drift_details.cap_version_match` 加上自己的 gate。

## 7. 為什麼 pre-A0 #4 的 run 是 `unverifiable`？

A0 #4 之前的 run 沒在 `agent-sessions.json` 寫 `agent_skills_baseline` 欄位。verifier **不會**從現況反推當時的 baseline（沒有可靠來源），所以這類 run 永遠是 `unverifiable`。

如果你想升級舊 run 的 verdict 能力，唯一辦法是重跑該 workflow（讓 `cap-workflow-exec.sh` 自動寫 baseline）。

## 8. Project layer skill drift 偵測（H2，v0.22.0+）

H2 把 H1 的 reserved-null `project_skill_diff` 升為 dual-axis：每個 run 同時看 builtin baseline 與 project layer (`<project_root>/.cap/skills.yaml` + `.cap/skills/*`) 是否漂移。

```bash
$ cap replay verify run_xxx
cap replay: drifted_incompatible — /Users/.../run_xxx
  reason: project_skills_changed=my-frontend-react18
  builtin: replayable
  project: drifted_incompatible (1 changed, 0 removed, 0 masked)
  verdict file:    /Users/.../run_xxx/replay-verdict.json
  snapshot mirror: /Users/.../run_xxx/snapshots/agent-skills.json
                   /Users/.../run_xxx/snapshots/project-skills.json
                   /Users/.../run_xxx/snapshots/binding-summary.json
```

verdict envelope 的 `drift_details.project_skill_diff` 帶完整 axis 細節：

```bash
$ cat run_xxx/replay-verdict.json | jq '.drift_details.project_skill_diff'
{
  "was_recorded": true,
  "axis_verdict": "drifted_incompatible",
  "project_dir_present_observed": true,
  "project_dir_present_current": true,
  "dir_hash_observed": "sha256:abc",
  "dir_hash_current": "sha256:def",
  "skills_used": ["my-frontend-react18", "my-qa-extended"],
  "skills_changed": ["my-frontend-react18"],
  "skills_removed": [],
  "skills_added_masked": [],
  "reason": "skills_changed=my-frontend-react18"
}
```

### Verdict 雙軸聚合

兩軸同時看，top-level verdict 取最嚴重者：
- 兩軸 replayable → top-level replayable
- 一軸 compatible → top-level compatible
- 任一軸 incompatible → top-level incompatible
- 單軸 unverifiable_axis 中立，不影響另一軸的 verdict
- 兩軸都 unverifiable_axis → top-level unverifiable

### 三種 was_recorded 狀態

H2 verifier 對 project axis 有三種精度：

1. **`was_recorded=true`**：envelope 帶完整 `project_skill_baseline` + `binding_summary`（H2 cap-workflow-exec.sh 自動 attach）→ per-skill 精準 drift。
2. **`was_recorded=false`，`axis_verdict in {replayable, drifted_compatible}`**：envelope 只有 `project_skill_baseline` 沒 `binding_summary` → 只能粗略判 dir_hash drift，**不會**升 incompatible。
3. **`was_recorded=false`，`axis_verdict=unverifiable_axis`**：連 `project_skill_baseline` 都沒（pre-H2 run 或 project layer 不存在）→ project axis 中立。

### Pre-H2 run 怎麼補

如果你想對 H2 之前的 run 啟用 project axis verdict：

```bash
# 補 project_skill_baseline 到 envelope
python3 engine/project_skills_snapshot.py attach <run_dir>/agent-sessions.json

# 重 verify（注意：缺 binding_summary 仍只有 coarse drift，binding_summary 無法 retrofit）
cap replay verify <run_id>
```

### H2 不做的部分

- Workflow YAML drift（該 run 用過的 workflow 檔被改）— ✓ H3 minimal 已加入（whole-file hash）。
- Capability schema / constitution drift — ✓ H3 minimal 已加入（whole-file hash）。
- Shared layer skill (`<cap_home>/shared/skills.yaml`) drift — H4+ deferred。
- Effective merged spec snapshot（合併過 disabled / replaces 後）— 後續更深層批次。

## 9. 5-軸 Multi-axis Drift 偵測（H3 minimal，v0.22.0+）

H3 minimal 在 H2 雙軸基礎上加 3 個 whole-file hash 軸，形成 5 軸完整 drift detection。

```bash
$ cap replay verify run_xxx
cap replay: drifted_compatible — /Users/.../run_xxx
  reason: workflow_yaml content_hash differs
  builtin: replayable
  project: replayable
  workflow: drifted_compatible (content_hash differs)
  constitution: replayable
  capability_schema: replayable
  ...
```

5 軸狀態 = top-level verdict 取最嚴重非中立軸：

| 軸 | 精度 | 可能的 axis verdict |
|---|---|---|
| builtin | per-prompt-file selection | replayable / drifted_compatible / drifted_incompatible / unverifiable_axis |
| project | per-skill_id selection | replayable / drifted_compatible / drifted_incompatible / unverifiable_axis |
| **workflow** | whole-file hash only | replayable / drifted_compatible / unverifiable_axis（**不會** drifted_incompatible） |
| **constitution** | whole-file hash only | replayable / drifted_compatible / unverifiable_axis |
| **capability_schema** | whole-file hash only | replayable / drifted_compatible / unverifiable_axis |

### H3 三軸的精度限制（重要）

H3 三軸只做 whole-file hash，**不可能輸出 `drifted_incompatible`**。看到 `drifted_compatible` 時表示「該檔案內容變了，但 verifier 無法判斷是否影響該 run 的行為」。Caller 要決定是否進一步檢視。

範例：

```bash
$ cat run_xxx/replay-verdict.json | jq '.drift_details.workflow_yaml_diff'
{
  "was_recorded": true,
  "axis_verdict": "drifted_compatible",
  "workflow_id": "project-spec-pipeline",
  "workflow_path": "/abs/path/to/wf.yaml",
  "source_layer": "builtin",
  "workflow_present_observed": true,
  "workflow_present_current": true,
  "content_hash_observed": "sha256:abc",
  "content_hash_current": "sha256:def",
  "reason": "workflow YAML content_hash differs"
}
```

要看實際變動，自己 `git diff` 或 `diff` 兩個 hash 對應的 file。

### H3 mirror 檔列表

每次 `cap replay verify` 寫到 `<run_dir>/snapshots/` 的檔案完整列表：

| Mirror 檔 | 來源 | 內容 |
|---|---|---|
| `agent-skills.json` | A0 #4 / H1 | builtin agent-skills baseline 完整 snapshot（含 prompt_files map） |
| `project-skills.json` | H2 | project layer skill baseline（含 skills_by_id map） |
| `binding-summary.json` | H2 | per-step binding 摘要（step_id × selected_skill_id × skill_source） |
| `workflow-yaml.json` | H3 | 該 run 用過的 workflow 檔的 content_hash + path + source_layer |
| `constitution.json` | H3 | constitution.yaml 的 content_hash + path + present |
| `capability-schema.json` | H3 | capabilities.yaml 的 content_hash + path + present |

### H3 不做的部分（deferred）

- Per-step / per-capability / per-field 精度 — H4+ 才會解開（會涉及 binding_summary 擴欄位 + 每個 step / capability / block 個別 hash）。
- Shared layer skill drift — H4+。
- `--strict-unverifiable` flag — H4+。

## 9. 為什麼 verdict file 會被覆寫？

verdict 是純函式：相同 stored baseline + 相同 current baseline → 永遠相同 verdict。沒必要保留歷史。重跑 `cap replay verify` 會以 in-memory 計算結果與 cached 比對，相同就不寫（避免無謂 IO），不同才覆寫。

## 10. 進階用法

### 10.1 只查不寫（read-only）

```bash
cap replay verify <run_id> --no-write
```

不建立 `replay-verdict.json` 或 `snapshots/`。適合：
- CI 中只想知道 verdict 但不想改 run dir
- 對唯讀 mounted 的 archived run

### 10.2 直接吃絕對路徑（跨 project）

```bash
cap replay verify /external/path/to/run_xxx/
```

繞過 run_id glob。適合：
- 從另一台機器掛載過來的 run
- Archived run dir 存放在非標準位置

### 10.3 機器消費

```bash
cap replay verify <run_id> --json
```

stdout 是 raw envelope，符合 `schemas/replay-verdict.schema.yaml`。

## 11. 相關文件

- [Replay contract policy SSOT](../../policies/replay-contract.md)
- [Replay verdict schema](../../schemas/replay-verdict.schema.yaml)
- [Replay design memo](REPLAY-CONTRACT-DESIGN.md)
- [Agent-skills baseline policy（A0 #1）](../../policies/agent-skills-baseline.md)
- [Agent-skills customization guide（A0 #5）](AGENT-SKILLS-CUSTOMIZATION.md)
- [A0 closeout](A0-CLOSEOUT.md)
