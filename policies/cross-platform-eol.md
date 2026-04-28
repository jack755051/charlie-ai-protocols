# Cross-Platform EOL Policy (v1.0)

> 本文件定義 Mac / Windows / WSL 混合開發環境下的換行符治理策略，目標是避免 `LF` / `CRLF` 在多機協作時反覆污染工作樹、製造雜訊 diff，並確保 repo 內文字檔格式穩定一致。

## 1. 核心結論

- **repo 內文字檔一律以 `LF` 為唯一標準**。
- **`.gitattributes` 是換行符的單一事實來源 (SSOT)**。
- **`.editorconfig` 是編輯器層的第二道保險**。
- **若主要在 WSL 開發，應優先使用 WSL 內的 git 與工具鏈**。
- **Windows 原生工具若直接改寫同一份 repo，最容易造成 `CRLF` 汙染**。

## 2. 問題本質

Git 的換行符治理有三層：

1. `.gitattributes`
2. `core.autocrlf`
3. 編輯器或格式化工具的預設行為

優先級由高到低，其中：

- `.gitattributes` 決定 repo 內檔案的正式規範
- `core.autocrlf` 只影響單台機器的 checkout / add / commit 行為
- 編輯器或外部工具若直接寫檔，可能繞過 Git 的正規化流程

因此，真正會反覆出問題的情境不是「有一台 Mac 加一台 Windows」，而是：

- repo 沒有明確的 EOL 規則
- Windows 端工具直接改寫工作樹
- 同一份 repo 被不同作業系統用不同預設 EOL 反覆存檔

## 3. Repo 層規範

本 repo 已採用以下治理方式：

- `.gitattributes`：文字檔預設 `LF`
- `.editorconfig`：編輯器預設 `LF`
- `.gitignore`：忽略 `.codex/` 等本機工具狀態

原則如下：

- `* text=auto eol=lf`
- 常見文字檔副檔名明確標記為 `text eol=lf`
- 二進位檔明確標記為 `binary`

## 4. 多機開發建議

### 4.1 Mac

- 可直接使用預設 `LF` 工作流
- 建議設定：

```bash
git config --global core.autocrlf input
```

### 4.2 Windows

- 若主要在 WSL 開發，**優先使用 WSL 內的 git**
- 避免用 Windows 原生 git 操作同一份 WSL repo
- 若必須在 Windows 原生環境操作，建議設定：

```bash
git config --global core.autocrlf false
```

### 4.3 WSL

- 將 WSL 視為 Linux 環境處理
- 盡量讓以下工具都在 WSL 內執行：
  - git
  - formatter
  - lint
  - codex / claude / 其他 AI CLI

## 5. VS Code 與編輯器建議

- 優先使用 VS Code Remote WSL 開啟 repo
- 避免 Windows 原生 VS Code 直接改寫 WSL repo
- 建議設定：

```json
{
  "files.eol": "\n",
  "files.insertFinalNewline": true,
  "files.trimFinalNewlines": true
}
```

- 若專案已有 `.editorconfig`，應以 `.editorconfig` 為主，不要讓個人設定覆蓋 repo 規則

## 6. 常見高風險來源

以下工具或行為最容易造成 EOL 反覆污染：

- Windows 原生編輯器直接修改 WSL repo
- 某些 formatter 或 IDE plugin 以 Windows 預設 `CRLF` 存檔
- 腳本批次改寫檔案但未保留原始 EOL
- 同步工具直接覆寫工作樹

## 7. 發生 EOL 汙染時的處理方式

若發現大量只有換行符差異的修改，建議流程：

1. 先確認是否只有 EOL 差異：

```bash
git diff --ignore-space-at-eol
```

2. 若確認只是換行符問題，先獨立整理，不要和功能變更混在同一筆 commit

3. 在乾淨工作樹執行正規化：

```bash
git add --renormalize .
git status
```

4. 以獨立 commit 提交，例如：

```bash
git commit -m "style(repo): normalize line endings"
```

## 8. 首次套用或新機器初始化

新機器首次進 repo 後，建議：

```bash
git config --global core.autocrlf false
```

若是 Mac / Linux，也可用：

```bash
git config --global core.autocrlf input
```

然後重新拉取並確認工作樹乾淨。

## 9. 文件放置策略

這類內容**不建議放在 `README.md` 主文**，因為：

- 它是開發環境治理規範，不是產品或 repo 導讀
- 細節偏操作政策，會污染 README 的主敘事
- 使用者並非每次進 repo 都需要先讀完整 EOL 治理細節

建議做法：

- 詳細版放 `policies/`
- `README.md` 最多只保留一行入口連結，或完全不提
- 若未來有更多開發環境規則，可再抽成獨立 `docs/runbooks/` 或 `docs/guides/`

## 10. 維護原則

- 不要再把 EOL 清理和功能變更混在同一筆 commit
- 只要發現跨平台工具引入 `CRLF`，優先修正工具路徑與編輯器設定
- repo 層規則若要擴充，應優先修改 `.gitattributes` 與 `.editorconfig`
