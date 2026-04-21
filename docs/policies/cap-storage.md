# CAP Storage Policy (v1.0)

> 本文件定義 CAP 的執行期儲存策略，目標是讓多人協作 repo 不再被 `.ai/`、`.agents/`、`workspace/` 類暫存資料污染，同時保留 CLI、GUI 與未來 OpenClaw runtime 的共用基礎。

## 1. 核心結論

- **不推翻整體架構**：保留既有 Agent、CLI wrapper、規則同步與文件治理機制。
- **抽離儲存層**：將「執行期狀態」與「專案正式成果」拆開。
- **repo 只放正式成果與專案設定**。
- **本機 CAP storage 放 logs、traces、drafts、sessions 與中間產物**。

## 2. 三層儲存模型

### 2.1 Repo 內正式資料
放進版本控制，供團隊協作：
- `docs/`
- `specs/`
- `CHANGELOG.md`
- `.cap.project.yaml`
- `.cap.agents.json`

### 2.2 本機專案儲存區
每個專案在本機有獨立儲存根：

```text
~/.cap/projects/<project_id>/
├── traces/
├── logs/
├── drafts/
├── handoffs/
├── reports/
├── cache/
└── sessions/
```

用途如下：
- `traces/`：結構化執行軌跡、session trace
- `logs/`：較長期或程序級 log
- `drafts/`：草稿與一次性中間產物
- `handoffs/`：任務交接單、修復建議單
- `reports/`：Lighthouse、Analytics、Audit 等報告
- `cache/`：索引、掃描結果、暫存 metadata
- `sessions/`：CLI / GUI / OpenClaw session state

### 2.3 Promote 機制
- **正式交付才進 repo**
- **執行中產物預設留在本機**
- 從本機升級到 repo 的路徑，應由明確指令或 agent 決策觸發
- 目前 CLI 入口：
  - `cap promote list`
  - `cap promote <local_rel_path> <repo_rel_path>`

## 3. 專案識別 (`project_id`)

CAP 依序用以下方式決定 `project_id`：
1. 讀取 repo 根目錄 `.cap.project.yaml` 的 `project_id`
2. 若無設定，使用 git repo 根目錄名稱

`project_id` 建議使用 kebab-case，且在團隊內維持穩定。

## 4. 格式策略

不要把所有產物都存成 `txt`。應依資料型態使用對應格式：

- 正式文件：`md`
- 結構化設定 / manifest：`yaml` 或 `json`
- trace / event stream：`jsonl`
- 傳統 log：`.log`
- 臨時純文字匯出：`txt`

`txt` 可作為輸出格式之一，但不應是 CAP 的唯一內部格式。

## 5. CLI / GUI / OpenClaw 共用原則

- CLI、桌面應用與未來 OpenClaw 都應共用同一套 storage model
- 前端介面只換「入口」與「runtime」，不換儲存結構
- Agent mapping 應逐步走向 registry 化，而不是綁死在路徑判斷
- Agent registry 應以 `.cap.agents.json` 為入口，詳細格式見 `docs/policies/agent-registry.md`

## 6. 安裝與初始化

安裝 CAP 後，預設建立：

```text
~/.cap/
└── projects/
```

第一次在某個專案內執行 `cap codex`、`cap claude` 或其他 storage-aware 指令時，CAP 會自動建立：

```text
~/.cap/projects/<project_id>/
```

## 7. 本 repo 的遷移策略

- 舊的 `workspace/` 保留為 **legacy / single-user sandbox**
- 新的 trace 與 session log 預設寫入 `~/.cap/projects/<project_id>/traces/`
- 新的報告與中間產物應優先寫入本機 CAP storage
- 正式文件仍寫入 repo `docs/`
