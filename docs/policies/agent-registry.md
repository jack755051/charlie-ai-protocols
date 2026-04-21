# CAP Agent Registry Policy (v1.0)

> 本文件定義 CAP 的 agent registry 結構，目標是讓 CLI、未來 GUI 與 OpenClaw runtime 都能共用同一份 agent 對應設定，而不將 alias 與 backend 寫死在單一 shell 腳本中。

## 1. 設計原則

- **alias 與 backend 解耦**：`$qa`、`$readme` 這類 alias 不應綁死在某個 CLI 腳本裡。
- **runtime 可替換**：未來可從 `builtin` 切換到 `openclaw`、其他 agent backend 或遠端服務。
- **設定檔可機器讀取**：registry 使用 JSON，便於 shell、Python、GUI 共同消費。

## 2. 預設檔案

repo 根目錄預設使用：

```text
.cap.agents.json
```

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
- `cap agent` 仍會以本地 `docs/agent-skills/*.md` 為實際 prompt 來源
- `provider != builtin` 的 runtime 切換保留給下一階段實作

## 5. 與未來 GUI / OpenClaw 的關係

- GUI 不應重做一套 agent 對應表，而應直接讀取 `.cap.agents.json`
- 若導入 OpenClaw，可在 `provider` / `cli` 欄位增加對應 runtime
- registry 是替換 agent backend 的入口，不是 prompt 內容的單一事實來源
