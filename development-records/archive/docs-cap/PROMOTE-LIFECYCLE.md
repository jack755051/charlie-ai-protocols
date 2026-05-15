# `cap promote` Lifecycle and CLI Reference

> 本文件是 P10 promote surface 的**使用者面向**操作指南。設計面 SSOT 在 `policies/runtime-promote.md`；本文件聚焦「拿到一個 run 之後怎麼安全把產物搬回 repo」。

## 1. 快速理解：runtime archive vs. repo SSOT

CAP 一次 workflow run 會產生兩類資料：

- **Runtime archive**（住在 `~/.cap/projects/<project_id>/`）：執行軌跡、step output、binding report、constitution snapshot 等。長期保留／清理由 `policies/run-archive.md` 的 lifecycle 規則 (active → archived → pruned) 治理。
- **Repo SSOT**（住在 `<project_root>/.cap/`）：團隊版本控管的正式檔，目前僅兩類：`.cap/constitution.yaml`（專案憲法）與 `.cap/workflows/<workflow_id>.yaml`（compiled workflow）。

**Promote = 從 runtime archive 把上面這兩類**（且**只有**這兩類）**搬回 repo SSOT。** 其他 runtime artifact（runtime-state、agent-sessions、route-history、step raw logs、binding report timestamped snapshot）一律不可 promote — 它們是執行過程資料，凍進 repo 只會讓 git history 變雜訊。

> 本文件規範的 typed surface 是預期的主要入口；既有 `cap promote list` 與 `cap promote <src> <dst>` 兩條 generic mode 仍然在（見 §6），但**不走** validation / backup / rollback pipeline，請只當作 escape hatch。

## 2. Lifecycle 三步走

```text
┌────────────────────┐
│ runtime run done   │  artifacts produced under ~/.cap/projects/<id>/
└─────────┬──────────┘
          ▼
┌─────────────────────────────────┐
│ workflow-result.json populates  │  promote_candidates[] non-empty when
│   promote_candidates[]          │  artifacts qualify (P10 #2 producer)
└─────────┬───────────────────────┘
          ▼
┌────────────────────────────────────┐
│ cap promote inspect <id>            │  read-only; shows source / target /
│                                    │  conflict / backup template /
│                                    │  validation plan
└─────────┬──────────────────────────┘
          ▼
┌──────────────────────────────────────────────┐
│ cap promote {project-constitution|workflow}  │  default --dry-run; describe
│   <id> [--apply] [--force]                   │  what would happen, no I/O
└─────────┬────────────────────────────────────┘
          ▼ (only with --apply)
┌──────────────────────────────────────────────┐
│ apply: backup (only on diff + --force) →     │  schema validation runs
│   write target → schema validate → rollback  │  always; failure rolls back
│   on validation failure                      │  to pre-apply state
└──────────────────────────────────────────────┘
```

**核心原則**：
- 不直接走 `--apply`，先 inspect / dry-run。
- target 已存在且不同時預設 halt。要覆寫必須 `--force`，且 `--force` 一定先寫 backup。
- 寫完一定 schema validate；失敗一定 rollback。
- backup 永不自動清；自己清。

## 3. `cap promote inspect <artifact_id>`

**用途**：read-only 查詢一個 task_id 或 workflow_id 是否能 promote、會走哪條路、會覆寫什麼、會驗證什麼。**不寫檔。**

```bash
cap promote inspect task-alpha            # 顯示六段資訊：Header / Source / Target / Validation
cap promote inspect wf-spec-v2 --json     # 同樣資料以 JSON 輸出（適合腳本消費）
cap promote inspect task-alpha --cap-home /tmp/sandbox-cap   # 測試環境 override
```

**Resolver 行為**：先把 `<artifact_id>` 當 task_id 找 constitution snapshot；若無，再當 workflow_id 找 compiled workflow snapshot。兩者都 miss → exit 1，error tag `promote_artifact_not_found`。

**Conflict 分類**（`conflict_kind` 欄位）：
- `no_target`：repo 還沒有這個檔；apply 會 fresh write，無 backup。
- `identical`：byte-equal source；apply 會 short-circuit (`already_promoted`)，無 backup。
- `diff`：repo 已有不同內容；apply **預設 halt**，加 `--force` 才覆寫，`--force` 一定先寫 backup `<target>.bak.<ISO>` 模板（inspect 顯示模板，apply 時換成真實 timestamp）。

**`--json` 輸出形狀**（穩定 contract）：

```json
{
  "ok": true,
  "candidate": { "source_path": "...", "target_path": "...", "artifact_type": "...", "reason": "..." },
  "target_exists": true,
  "conflict_kind": "diff",
  "backup_path": "/abs/path/.cap/constitution.yaml.bak.<ISO>",
  "backup_required": true,
  "validation_schema": "schemas/project-constitution.schema.yaml",
  "smoke_plan": { "schema_validate": { "enabled": true, "schema_path": "..." } }
}
```

## 4. `cap promote project-constitution <task_id>`

**用途**：把 `<cap_home>/projects/<id>/constitutions/<task_id>/constitution.{yaml,yml,json}` snapshot 搬到 `<project_root>/.cap/constitution.yaml`。

**Target 嚴格規則**（policy §3.1）：唯一允許 target 是 `<project_root>/.cap/constitution.yaml`（namespaced）。**不寫** legacy `.cap.constitution.yaml`；如果你還在用 legacy，先跑 `cap project migrate-config` 收編。

```bash
# 一律先 dry-run（這是預設 — 沒加 --apply 就是 dry-run）
cap promote project-constitution task-alpha
cap promote project-constitution task-alpha --json

# 確認 dry-run 看起來對，再 --apply
cap promote project-constitution task-alpha --apply

# 已存在不同內容 → 預設 halt；確定要覆寫才 --force
cap promote project-constitution task-alpha --apply --force
```

**Validation**：apply 寫完 target 後，runtime 會把 `<project_root>/.cap/constitution.yaml` 餵 `schemas/project-constitution.schema.yaml` 驗一次。失敗時：
- 如果這次是 fresh write（target 原本不存在）→ runtime `unlink` 掉剛寫的 target。
- 如果這次是 force 覆寫（target 原本存在）→ runtime 從 backup 還原。
- Action 變 `validation_failed_rolled_back`，exit 1，repo 回到 promote 前的狀態。

## 5. `cap promote workflow <workflow_id>`

**用途**：把 `<cap_home>/projects/<id>/compiled-workflows/<workflow_id>/<latest>.json` snapshot 搬到 `<project_root>/.cap/workflows/<workflow_id>.yaml`。

**Target 嚴格規則**（policy §3.2）：唯一允許 target 是 `<project_root>/.cap/workflows/<workflow_id>.yaml`，檔名必須跟 `workflow_id` 完全一致。**不允許 partial override** — 想改某幾個 step 的話，promote 整檔下來自己改，不要試圖只搬一部分（同 P9 §4.3 鐵則）。

```bash
cap promote workflow project-spec-pipeline             # dry-run，看會發生什麼
cap promote workflow project-spec-pipeline --apply     # 實際寫檔
cap promote workflow project-spec-pipeline --apply --force  # 覆寫舊版（自動 backup）
```

**Final-state 安全網的兩道機制**：
1. **Producer 端（自動建議）**：`workflow-result.json.promote_candidates[]` 只在 `final_state == "completed"` 時 emit compiled_workflow candidate。失敗 / 阻擋 / 取消的 run 不會出現在自動建議清單。
2. **使用者直接呼叫**（`cap promote workflow <id>`）：如果你是直接打這條指令，runtime 視為 deliberate override，**不**再次過濾 final_state — 但 post-apply 的 schema validation 是結構性安全網，會擋掉壞掉的 compiled workflow。

**Validation** 同 §4，差異只是 schema 換成 `schemas/compiled-workflow.schema.yaml`。

## 6. Generic escape hatch：`cap promote list` / `cap promote <src> <dst>`

```bash
cap promote list [drafts|reports|all]
cap promote <local_rel_path> <repo_rel_path>
```

**這兩條保留作為 escape hatch**，**不**走 §3-§5 的 typed pipeline：
- 沒有 candidate 自動偵測（你自己挑路徑）。
- **沒有 backup**（直接 `cp` 覆蓋）。
- **沒有 schema validation**。
- **沒有 rollback**。

什麼時候用：要 promote 兩個 typed type 之外的東西（例如 ad-hoc reports / drafts），且你願意自己負責正確性。**主要 promote 流程請走 typed surface（§3-§5）。**

## 7. 共用 flag

| Flag | typed subcommand | 行為 |
|---|---|---|
| 預設（無 `--apply`） | `inspect` 不需要、其他兩條 | dry-run：描述會發生什麼，不寫任何檔 |
| `--apply` | `project-constitution` / `workflow` | 實際執行寫入流程 |
| `--force` | `project-constitution` / `workflow` | target 已存在且不同時，先寫 `<target>.bak.<ISO>` 再覆蓋；無 `--force` 預設 halt |
| `--json` | 三條都支援 | 吐固定形狀 JSON 而非 human text |
| `--project-root <dir>` | 三條都支援 | 覆寫 `CAP_PROJECT_ROOT`，主要給測試 sandbox 用 |
| `--cap-home <dir>` | 三條都支援 | 覆寫 `CAP_HOME`，同上 |
| `--project-id <id>` | 三條都支援 | 覆寫 auto-resolve 的 project_id |

## 8. Backup / validation / rollback 細節

### 8.1 Backup 命名

- inspect 階段顯示：`<target>.bak.<ISO>`（template，提醒實際 timestamp 在 apply 才產生）
- apply 階段實際寫：`<target>.bak.20260506T130000Z`（UTC ISO8601）
- 同一 target 多次 force 覆寫會產生多個 backup（每次 timestamp 不同），runtime **不**自動 prune；要清自己清。
- 把 `*.bak.*` 加進 `.gitignore` 避免誤 commit backup。

### 8.2 Validation

- 走 `jsonschema.Draft202012Validator`（缺套件時 fallback `engine.step_runtime.validate_jsonschema_fallback`）。
- target 自動偵測格式：`.json` 走 JSON parse、其他（含 `.yaml` / `.yml` / 無副檔名）走 YAML parse。
- 結果結構：`{"ok": bool, "errors": list[str]}`，跟 CAP 其他驗證一致。

### 8.3 Rollback

| 觸發條件 | 行為 |
|---|---|
| Validation 失敗 + target 原本不存在 | `unlink(missing_ok=True)` 清掉 fresh write |
| Validation 失敗 + target 原本存在 + 有 backup | `shutil.copy2(backup, target)` 從 backup 還原 |
| Validation 失敗 + target 原本存在但無 backup | 視為 rollback fail，action=`validation_failed_rollback_failed`，**停在現場**等使用者人工介入 |

Rollback 後 backup 檔本身**保留**，因為它是審計 / 復原素材，不該因為 promote 失敗就連帶清掉。

## 9. Action enum 速查

`cap promote project-constitution` / `cap promote workflow` 的 JSON 輸出 `action` 欄位。

| Action | 何時出現 | repo 是否被改 |
|---|---|---|
| `dry_run_no_target` | 預設 dry-run, target 不存在 | 否 |
| `dry_run_identical` | 預設 dry-run, target byte-equal source | 否 |
| `dry_run_conflict` | 預設 dry-run, target diff, 無 `--force` | 否 |
| `dry_run_force_overwrite` | 預設 dry-run, target diff, 有 `--force` | 否 |
| `applied_fresh` | `--apply`, target 不存在 → 寫入 | 是（fresh） |
| `applied_identical_skip` | `--apply`, target byte-equal source | 否 |
| `applied_force_with_backup` | `--apply --force`, target diff → backup + 寫入 | 是（覆蓋 + backup 產生） |
| `halted_conflict` | `--apply`, target diff, 無 `--force` | 否 |
| `halted_type_mismatch` | typed subcommand 用在錯的 artifact_type 上 | 否 |
| `halted_backup_failed` | backup 寫不下去（磁碟 / 權限） | 否 |
| `halted_write_failed` | target 寫不下去 | 否 |
| `validation_failed_rolled_back` | apply 寫了 target，schema validate 失敗，rollback 成功 | 否（已 rollback） |
| `validation_failed_rollback_failed` | apply 寫了 target，validate 失敗，rollback 也失敗 | 是（不一致狀態 — 人工介入） |

## 10. 跟 P7 / P9 / archive 的銜接

- **P7 result report builder**：`workflow-result.json.promote_candidates[]` 由 P10 #2 producer 填，schema 對齊 `policies/runtime-promote.md` §5.2。
- **P9 source resolver**：candidate 與 target 都對齊 P9 三層 layer 表的 project 路徑（`<project_root>/.cap/`）；shared layer 不在預設 promotable target。
- **`policies/run-archive.md`**：archive 管 `<run_dir>` 的 lifecycle，promote 管「從 archive 拷出去進 repo」。一個 run 可以同時被 archive 與被 promote — 兩件事互不取代。

## 11. 常見問題

**Q：我看到 `promote_candidates: []` — 為什麼空？**
- 跑出來的 run `final_state != "completed"`：compiled_workflow 不會 emit。改重跑或直接呼 `cap promote workflow <id>` 走 user override。
- task 沒有 task_id（直接跑 `cap workflow` 而非 task-scoped 流程）：constitution snapshot 不存在，沒得 promote。
- runtime tree 缺 source 檔（已被 prune 或人工清掉）：靜默 no-emit。

**Q：apply 失敗 backup 留在那邊很煩。**
是設計使然（policy §4.3：backup 永不自動清）。建議把 `*.bak.*` 加進 `.gitignore`，定期人工 audit 後清掉。

**Q：partial override 為何禁？**
schema validation gate 已經驗整份檔；partial merge 會把 schema 噪音化。要客製整份 fork 一份到 `<project_root>/.cap/workflows/<id>.yaml` 自己改即可（同 P9 §4.3）。

**Q：`cap promote inspect` 對失敗 run 的 compiled workflow 為何還能描述？**
inspect 是 read-only 觀察用，故意不過濾 final_state，這樣使用者可以「看一眼」失敗 run 的狀態。真要 promote 還是會被 schema validation 攔下（如果產出實際壞掉的話）。

## 12. 進階：腳本消費 `--json`

完整 JSON shape 對照 `engine/promote_cli.py` 的 dataclass `ApplyResult`（apply path）與 `ResolvedPromote`（inspect path）。穩定欄位（不會在 v1 series 內 break）：

- `inspect`：`ok` / `candidate` / `target_exists` / `conflict_kind` / `backup_path` / `backup_required` / `validation_schema` / `smoke_plan`。
- `apply`：`ok` / `action` / `artifact_id` / `artifact_type` / `source_path` / `target_path` / `target_existed_before` / `backup_path` / `validation` / `error` / `detail`。

腳本應依 `action` enum 分流，不要 grep human text。
