# Design Source Runtime Boundary (v0.21.0+)

> SSOT 文件：把 v0.20.0–v0.21.0 散落在 schema、capability、workflow、agent-skill、shell script 與測試中的 design source 規則收成一份權威藍圖。本文件是消費端（agent / runtime / 文件）對「設計稿從哪來、怎麼用」唯一應該查的地方。

---

## 1. 四層模型 (Four-Layer Model)

```
┌─ Layer 1 ──────────────────────────────────────────────────────┐
│  ~/.cap/designs/                                               │
│  全域 raw package registry — 多 package 共存，每個子目錄是     │
│  一份獨立的設計稿；唯讀，不在 cap workflow 內修改。              │
└────────────────────────────────────────────────────────────────┘
           │
           ▼ (selection)
┌─ Layer 2 ──────────────────────────────────────────────────────┐
│  constitution.design_source                                    │
│  專案憲法的 design SSOT — 顯式記錄該專案綁定哪一份 package、   │
│  甚麼 type、source_path、mode。runtime 與 agent 一律從這裡讀。 │
└────────────────────────────────────────────────────────────────┘
           │
           ▼ (ingest)
┌─ Layer 3 ──────────────────────────────────────────────────────┐
│  docs/design/                                                   │
│  agent consumption layer — 由 ingest_design_source step 產生   │
│  的 hash-cached 摘要：source-summary.md / source-tree.txt /    │
│  design-source.yaml + .source-hash.txt sentinel。               │
│  AI agent 預設只讀本層；不直接面對 raw package。                │
└────────────────────────────────────────────────────────────────┘
           │
           ▼ (fallback only)
┌─ Layer 4 ──────────────────────────────────────────────────────┐
│  raw package re-read                                            │
│  Layer 3 摘要對某具體決策不足時，回 Layer 1/2 讀對應子檔案。     │
│  例外路徑，不是預設行為。                                       │
└────────────────────────────────────────────────────────────────┘
```

---

## 2. 各層權威定義

### Layer 1 — `~/.cap/designs/` 全域 raw package registry

| 屬性 | 規則 |
|---|---|
| 路徑 | `~/.cap/designs/<package-name>/` 每個子目錄一份 package |
| 性質 | **唯讀**；CAP 任何 workflow / script 禁止寫入此目錄 |
| 命名 | 不再假設 `<package-name>` 等於 `<project_id>`；同一 project 可綁不同 package、同一 package 可服務多 project |
| 0/1/N 偵測 | `engine/design_prompt.py` 的 `_list_design_packages()`：0=fallback to no-design、1=auto-select、N=要求顯式選擇 |
| 顯式選擇旗標 | `cap workflow run --design-package <name> ...`（v0.20.0+ 推薦）；legacy `--design-source local-design --design-path <path>` 維持相容 |

### Layer 2 — `constitution.design_source` 專案級 SSOT

| 欄位 | 必填 | 說明 |
|---|---|---|
| `type` | ✓ | enum: `none` / `local_design_package` / `claude_design` / `figma_mcp` / `figma_import_script` |
| `design_root` | △ | 預設 `~/.cap/designs`；type 為 `local_design_package` 時建議寫明 |
| `package` | △ | type 為 `local_design_package` 時必填 |
| `source_path` | △ | 推薦顯式寫死絕對路徑；空缺時由 design_root + package 推導 |
| `mode` | ✓ | `read_only_reference`（預設）；`read_write` 保留未用 |
| `figma_target` / `script_path` | 條件 | 對應 figma 系列 type 才填 |

完整 schema：`schemas/project-constitution.schema.yaml` `design_source` block。

**缺 block 或 type=none**：runtime / ingest 都視為「本專案無 design source」，graceful no-op，不阻擋其他 step。

### Layer 3 — `docs/design/` agent consumption layer

由 `scripts/workflows/ingest-design-source.sh`（capability `design_source_ingest`）產生：

| 檔案 | 用途 |
|---|---|
| `docs/design/source-summary.md` | human readable 摘要（package 元資訊 + tree） |
| `docs/design/source-tree.txt` | deterministic 排序的相對路徑清單 |
| `docs/design/design-source.yaml` | machine readable metadata（type / source_path / package / sha256 / generated_at） |
| `docs/design/.source-hash.txt` | sentinel（SHA-256 over relative-path + content） |

**Cache 行為**：sentinel hash 不變且三件式齊備 → cache hit、跳過 rebuild、mtime 不變。

### Layer 4 — raw package re-read（fallback only）

agent 在 Layer 3 摘要不足時才回頭讀 raw package：

- 例如 UI agent 設計某個 frame 細節，summary 只列 file path 不夠，需要打開 `~/.cap/designs/<pkg>/project/<frame>.jsx`
- 由 agent 自行決策；不是預設路徑
- 仍不得寫入 `~/.cap/designs/`

---

## 3. 解析鏈 (Resolution Chain)

當 runtime 或 script 需要解析「設計稿來源路徑」時，採三段式：

```
1. constitution.design_source.source_path
       │ (顯式宣告，最高優先)
       ▼
2. constitution.design_source.{design_root}/{package}
       │ (從零件組成)
       ▼
3. ~/.cap/designs/<project_id>            ← legacy fallback
       │ (deprecated; 待 v0.22.0+ 移除)
       ▼
4. (no design source) — graceful no-op
```

**實作**：
- Python：`engine/step_runtime.py` `_design_source_path()`
- Shell：`scripts/workflows/ingest-design-source.sh`（透過 import step_runtime）

兩者必須 **行為等價**；改動其中一個時測試（`tests/scripts/test-design-source-resolution.sh` 9 cases / 15 assertions）必須同時驗證。

---

## 4. Workflow 接觸點

| Workflow Step | 角色 | 對應 capability | 對應檔案 |
|---|---|---|---|
| `cap workflow run --augment` | CLI 注入 design ritual block 到 prompt | — | `engine/design_prompt.py` |
| `draft_constitution` (project-constitution.yaml) | 把 design ritual 落地為 `design_source` block | `project_constitution` | supervisor agent skill |
| `ingest_design_source` (project-spec-pipeline.yaml) | 把 raw package 收成 docs/design 三件式 | `design_source_ingest` | `scripts/workflows/ingest-design-source.sh` |
| `ui` (project-spec-pipeline.yaml) | summary-first 消費 docs/design/* | `ui_design` | `agent-skills/03-ui-agent.md` |
| `frontend` (project-implementation-pipeline.yaml) | 同上 | `frontend_implementation` | `agent-skills/04-frontend-agent.md` |

---

## 5. 不變式 (Invariants)

1. **Single source of truth**：`constitution.design_source` 是專案級 SSOT。runtime / agent / shell / 測試一律從這裡讀，不從 `<project_id>` 推導 package name。
2. **Read-only registry**：`~/.cap/designs/` 永遠唯讀，CAP workflow 不寫入此目錄。
3. **Summary-first**：UI / frontend 等下游 agent 預設讀 `docs/design/source-summary.md`，不直接展開 raw package。
4. **Hash-gated rebuild**：ingest_design_source 用 SHA-256 sentinel 控制是否 rebuild；source 不變則 cache hit。
5. **Graceful no-op**：design_source 缺 block / type=none / source_path 缺漏，皆視為「本專案無 design source」，不阻擋其他 step。
6. **Halt on dishonesty**：source_path 顯式宣告但磁碟缺失、type 是 unknown 值、registry 多 package 但無顯式選擇 → halt，不偽造 summary。

---

## 6. Migration & Deprecation

| 項目 | 狀態 | 計畫 |
|---|---|---|
| Layer 2 `design_source` block | 可選 → **建議顯式記錄** | v0.22.0+ 進一步建議 schema required |
| Layer 1→4 `~/.cap/designs/<project_id>` legacy fallback | **deprecated**（仍 work） | v0.22.0+ 列為 deprecated；v0.23.0+ 評估移除 |
| 現有專案憲法批次補 `design_source` block | **手動 / token-monitor 已示範** | `project-constitution-design-source-migration.yaml` workflow 規劃中（收斂清單 #1，deferred） |

---

## 7. 測試覆蓋

| 測試 | 範圍 | Cases / Assertions |
|---|---|---|
| `tests/scripts/test-design-source-resolution.sh` | Layer 1→2→4 解析鏈 + design_prompt 多 package | 9 / 15 |
| `tests/scripts/test-cap-workflow-design-package-forwarding.sh` | wrapper 把 `--design-package` 傳到 design_prompt | 4 / 5 |
| `tests/scripts/test-design-source-ingest.sh` | Layer 2→3 ingest 與 hash cache 全生命週期 | 6 / 21 |

三套測試 + smoke wrapper 構成 design source 行為的 regression gate。

---

## 8. 相關文件

- `schemas/project-constitution.schema.yaml`：Layer 2 schema
- `schemas/design-source-templates.yaml`：CLI prompt augmentation 模板
- `schemas/capabilities.yaml`：`design_source_ingest` capability 契約
- `schemas/workflows/project-constitution.yaml`：draft_constitution step 寫入 design_source
- `schemas/workflows/project-spec-pipeline.yaml`：ingest_design_source + UI summary-first
- `scripts/workflows/ingest-design-source.sh`：Layer 2 → Layer 3 deterministic ingest
- `engine/design_prompt.py`：CLI augmentation entry
- `engine/step_runtime.py` `_design_source_path()`：runtime resolution

---

## 9. 版本歷程

- **v0.20.0**：把 `~/.cap/designs/` 升級為 multi-package registry；憲法新增 `design_source` block。
- **v0.20.1**：把 `--design-package` 旗標從 engine 接通到 wrapper / usage / workflow YAML。
- **v0.21.0**：新增 `ingest_design_source` step + `docs/design/` 三件式 + hash cache；UI step 改為 summary-first。
- **v0.21.1**：本文件首次 SSOT 收斂；prompt contract 收緊（連動 Task Constitution 八固定欄位）。
