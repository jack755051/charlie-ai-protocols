# CAP Agent Registry Policy (v1.2)

> 本文件定義 CAP 的現行 agent registry 結構。
> 自 v1.2 起，`.cap.agents.json` 定位為**正式相容層**；workflow binding 的正式入口改由 `RuntimeBinder` 負責，並優先讀取 `.cap.skills.yaml`，缺席時再轉接 `.cap.agents.json`。

## 1. 設計原則

- **alias 與 backend 解耦**：`$qa`、`$readme` 這類 alias 不應綁死在某個 CLI 腳本裡。
- **runtime 可替換**：未來可從 `builtin` 切換到 `openclaw`、其他 agent backend 或遠端服務。
- **設定檔可機器讀取**：registry 使用 JSON，便於 shell、Python、GUI 共同消費。
- **workflow 不直接依賴 agent registry**：workflow 只綁 capability；實際 skill / agent 由 `RuntimeBinder` 在執行前解析。

## 2. 預設檔案

repo 根目錄預設使用：

```text
.cap.agents.json
```

> 正式 runtime 狀態：
> - `cap agent`：仍直接使用 `.cap.agents.json`
> - `cap workflow plan / bind / run`：由 `runtime_binder` 優先讀 `.cap.skills.yaml`；若缺少，會自動將 `.cap.agents.json` 轉為 legacy adapter

## 3. 結構

```json
{
  "default_cli": "codex",
  "agents": {
    "readme": {
      "provider": "builtin",
      "prompt_file": "101-readme-agent.md",
      "cli": "codex"
    }
  }
}
```

### 3.1 欄位說明

| 欄位 | 型別 | 說明 |
|---|---|---|
| `default_cli` | string | 預設啟動 CLI，例如 `codex`、`claude` |
| `agents.<alias>.provider` | string | 目前 provider，例如 `builtin`；未來可擴充 `openclaw` |
| `agents.<alias>.prompt_file` | string | 目前對應的本地 agent prompt 檔 |
| `agents.<alias>.cli` | string | 該 alias 的預設啟動 CLI |

## 4. 現階段限制

- v1 僅實作 `builtin` provider
- `cap agent` 仍會以本地 `agent-skills/*.md` 為實際 prompt 來源
- `provider != builtin` 的 runtime 切換保留給下一階段實作
- `.cap.agents.json` 不承載 marketplace 級的 capability policy、version compatibility 與 fallback policy

## 5. 與 `.cap.skills.yaml` 的關係

- **主規劃 registry**：`.cap.skills.yaml`
  - 用途：workflow binding、skill marketplace、binding policy、fallback 與 unresolved binding
  - 狀態：`cap workflow` 的優先輸入；schema 穩定版、遠端 marketplace 與安裝/升級 CLI 仍屬 draft
- **現行相容 registry**：`.cap.agents.json`
  - 用途：固定 alias → prompt_file / cli 的執行期綁定
  - 狀態：formal / compatibility path

結論：

- 新能力優先往 `.cap.skills.yaml` 擴充
- `cap workflow plan / bind / run` 已由 `RuntimeBinder` 優先使用 `.cap.skills.yaml`
- `cap agent` 與 legacy loader 仍短期保留 `.cap.agents.json`
- 在 `.cap.skills.yaml` 缺席時，runtime 允許由 `.cap.agents.json` 自動轉接，避免 workflow preflight 直接失效

## 6. 與未來 GUI / OpenClaw 的關係

- GUI 不應重做一套 agent 對應表，而應直接讀取 `.cap.agents.json`
- 若導入 OpenClaw，可在 `provider` / `cli` 欄位增加對應 runtime
- registry 是替換 agent backend 的入口，不是 prompt 內容的單一事實來源
