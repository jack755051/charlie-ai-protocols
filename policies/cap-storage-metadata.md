# CAP Storage Metadata Policy (v1.0)

> 本文件定義 `~/.cap/projects/<project_id>/.identity.json` 的治理規則：metadata shape SSOT、schema_version 演進政策、migration path、與 `cap_version` 來源。 P1 #4 health check、P1 #5–7 `cap project status / init / doctor` 與 P10 promote workflow 都會消費此 metadata。

## 1. SSOT 邊界

- **Schema SSOT**：`schemas/identity-ledger.schema.yaml`（v2 normalized contract）。任何對 ledger 結構的變更必須先改 schema，再改 producer / consumer。
- **Producer SSOT**：`scripts/cap-paths.sh` 與 `engine/project_context_loader.py` 必須 lock-step 寫出符合 schema 的 ledger，行為差異視為治理 bug。
- **Storage location SSOT**：`~/.cap/projects/<project_id>/.identity.json`。`CAP_HOME` 可覆寫 `~/.cap`，但 ledger 檔名固定為 `.identity.json`，避免多檔治理混亂。

## 2. `cap_version` SSOT 與 release 同步

- **單一來源**：`repo.manifest.yaml` 頂層 `cap_version` 欄位。
- **讀取規則**：
  - cap-paths 與 project_context_loader 必須**只讀**該欄位。
  - 欄位不存在或值為空 → ledger 寫入 `cap_version: null`（合法）。
  - **嚴禁** fallback 到 `git describe --tags`、`git rev-parse`、CHANGELOG 解析、或任何動態狀態 — 這些會把開發中的 dev tag / branch state 寫進 governance metadata，破壞 audit 一致性。
  - **嚴禁**讀 `repo.manifest.yaml` `commands.version` 欄位（那是 CLI 子命令名 `cap version`，不是版本字串）。
  - **嚴禁**把 `repo.manifest.yaml` 的 `schema_version`（manifest 自己的 schema 版本）誤當 cap 版本。
- **寫入時點**：
  - 首次建立 ledger（first-time `cap-paths ensure`）。
  - 從 v1 → v2 migration 時。
  - 既有 v2 ledger 不會在每次 `ensure` 重新覆寫 `cap_version`（避免歷史漂移）。
- **Release 同步義務**：每次 cap 正式發版必須在 release workflow 中同步 bump `repo.manifest.yaml` 的 `cap_version`，與 git tag、CHANGELOG.md、release notes 三者一致。release workflow 的 watcher gate 應在發版前驗證四者對齊。

## 3. Schema Versioning 政策

### 3.1 何時需要 bump `schema_version`

- **Bump（破壞性變更）**：
  - 新增 required 欄位
  - 移除 / 重新命名既有欄位
  - 改變既有欄位的 type
  - 收窄 enum（移除既有合法值）
  - 改變欄位語意（即使 shape 一致）
- **不需 bump（前向相容變更）**：
  - 新增 optional 欄位（舊 cap 讀新 ledger 安全忽略未知 key）
  - 擴大 enum（新增合法值，且既有值仍合法）
  - 加強 description（純文件）

### 3.2 舊 cap 讀新 ledger（forward-incompat halt）

- 若 ledger 的 `schema_version` 大於本 cap 已知最高版本，cap-paths 必須 **halt with exit 41 / `schema_validation_failed`**。
- **不得** best-effort 解析未知格式 — ledger 是治理 artifact，被舊版誤寫會破壞 audit 一致性，比讓使用者升級 cap 還糟。
- 訊息應指引：升級 cap，或在隔離環境刪除該 storage 重建。

### 3.3 新 cap 讀舊 ledger（auto-migrate）

- 若 ledger 的 `schema_version` 小於當前版本，cap-paths 必須在 `ensure` subcommand 自動 migrate：
  1. 補齊新版要求的 required 欄位（用合理預設或現有資訊推導）。
  2. 在 `previous_versions[]` 追加 `{schema_version: <舊版>, migrated_to_at: <當下 ISO>}`。
  3. 寫入 `migrated_at: <當下 ISO>`。
  4. 寫入 `schema_version: <新版>`。
  5. 既有的 `created_at` / `origin_path` / `project_id` / `resolved_mode` **不得**被 migration 覆寫，這些是 immutable 治理 fact。
- **Read-only subcommand（`get` / `show`）禁止觸發 migration**；只允許 collision check 與 forward-incompat halt。read-only call 寫 ledger 會違反 P1 #3 治理意圖（混淆 health check 對「真的進入 workflow」與「被工具讀過」的判斷）。

## 4. `last_resolved_at` 更新政策

- **只在 `ensure` subcommand 寫入**。`get` / `show` 等 read-only subcommand **嚴禁**更新此欄位。
- **意圖**：health check (P1 #4) 與 promote workflow (P10) 用此判定「project storage 是否仍被 workflow 主動使用」。如果 read-only call 也更新，這個訊號會被「被工具掃過 N 次」污染。
- **Race condition 處置**：若同一 project 同時被多個 cap workflow 並行呼叫 `ensure`，最後寫入者勝出（last-write-wins）；不引入 lock，因為單一 host 上單一 project 並行 workflow 是罕見場景，且 `last_resolved_at` 是 best-effort metadata。

## 5. Collision Detection 與 Schema Validation 邊界

- **Schema validation**（exit 41）：ledger JSON parse 失敗、required 欄位缺失、enum 超出、forward-incompat schema_version > 當前最高版本。
- **Identity collision**（exit 53）：ledger 結構合法，但 `origin_path` 與當前 PROJECT_ROOT 不符。
- **Identity unresolvable**（exit 52）：根本無法決定 project_id（非 git folder + 無 config + 無 override + 無 fallback flag）；此時 ledger 還沒 read 就 halt，不會走到本文件規則。

兩個分類獨立：collision 不該被誤判為 schema_validation_failed，反之亦然。`policies/workflow-executor-exit-codes.md` 的 identity-class executor 章節為權威分類來源。

## 6. 未來規劃（不在本 policy 範圍）

- **P1 #4 health check**：消費 `last_resolved_at`、`previous_versions[]`、`cap_version` 判定 staleness 與 migration 異常。
- **P1 #5 `cap project init`**：互動式建立 `.cap.project.yaml` + ledger，給 non-git folder 補 identity 來源。
- **P1 #7 `cap project doctor`**：偵測 ledger 與 `.cap.project.yaml` 不一致、ledger orphaned（origin_path 已不存在）等異常。
- **P10 promote workflow**：promote validated artifact 時讀取 `cap_version` 判定來源 cap 版本，避免跨版本污染 shared registry。
