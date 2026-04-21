# README Governance Policy (v1.0)

> 本文件定義多 repo README 與 `repo.manifest.yaml` 的統一治理規則，目標是讓「人可讀、機可解析」同時成立，供排程 action、repo intake 與知識盤點流程穩定使用。

## 1. 核心原則

- **雙層設計**：
  - `repo.manifest.yaml` 為機器優先的結構化來源。
  - `README.md` 為人類優先的導讀入口。
- **單一事實來源 (SSOT)**：
  - 若 repo 同時存在 `repo.manifest.yaml` 與 README front matter，**以 `repo.manifest.yaml` 為準**。
  - README front matter 應為摘要鏡像，不得與 manifest 衝突。
- **真實性優先**：
  - `commands`、`stack`、`entrypoints`、`interfaces` 必須能在 repo 中找到對照證據。
- **最小改動優先**：
  - 既有 README 的敘事內容可保留，但必須補齊固定 metadata 與章節骨架。

## 2. 檔案策略

### 2.1 檔案策略（強制路由）

> ⚠️ 以下為強制路由規則，`101-readme-agent` 必須依據 repo 現況判定情境後嚴格執行對應策略，不可無條件 fallback。

- **README 缺失或極度鬆散（< 30 行）**：
  - 允許使用單檔 `README.md`，頂部帶完整 YAML front matter。
- **README 已有基本內容（30–80 行）**：
  - 允許在 README 頂部補精簡 front matter（僅摘要級欄位），完整結構化資料建議另建 `repo.manifest.yaml`。
- **README 已完整（> 80 行，含 3+ 固定章節）**：
  - **必須**新增 `repo.manifest.yaml` 作為機器 SSOT。
  - **README 不加 front matter**，僅保留人類導讀內容。

### 2.2 Parser 讀取順序
自動化工具應依下列順序讀取：
1. `repo.manifest.yaml`
2. `README.md` front matter
3. `README.md` 固定章節內容

若三者互相衝突，應回報錯誤，不得自行猜測。

## 3. `repo.manifest.yaml` Schema

### 3.1 必填欄位
- `schema_version`
- `repo_id`
- `name`
- `summary`
- `owner`
- `status`
- `stack`
- `entrypoints`
- `commands`
- `interfaces`
- `tags`

### 3.2 建議欄位
- `visibility`
- `domain`
- `docs`
- `integrations`
- `deploy`
- `notes`

### 3.3 欄位定義

| 欄位 | 型別 | 說明 |
|---|---|---|
| `schema_version` | integer | manifest schema 版本，初版固定為 `1` |
| `repo_id` | string | 穩定且唯一的 repo 識別碼，建議 kebab-case |
| `name` | string | 人類可讀名稱 |
| `summary` | string | 一句話說明 repo 目的 |
| `owner` | string | 維護團隊或責任人 |
| `status` | enum | `active` / `maintenance` / `experimental` / `deprecated` / `archived` |
| `visibility` | enum | `public` / `private` / `internal` |
| `domain` | string | 業務領域，例如 `payments`、`auth` |
| `stack` | string[] | 技術棧清單 |
| `entrypoints` | object | 關鍵入口檔與路徑 |
| `commands` | object | 可執行命令集合 |
| `interfaces` | object | 對外介面能力宣告 |
| `docs` | object | 額外文件入口 |
| `integrations` | string[] | 第三方依賴或外部平台 |
| `tags` | string[] | 搜尋與分類標籤 |
| `deploy` | object | 部署資訊摘要 |
| `notes` | string[] | 額外注意事項 |

### 3.4 `commands` 最小要求
至少應包含：
- `install`
- `dev`
- `test`

若該 repo 不適用某命令，值應填 `not_applicable`，不得留空字串。

### 3.5 `interfaces` 最小要求
至少宣告：
- `api`
- `worker`
- `cron`

值型別固定為 boolean。

## 4. README 標準骨架

README 建議採用以下固定順序：

1. `Purpose`
2. `Scope`
3. `Architecture`
4. `Project Structure`
5. `Runbook`
6. `Interfaces`
7. `Dependencies`
8. `Notes`

### 4.1 最小 README 範例

```md
---
schema_version: 1
repo_id: billing-api
name: Billing API
summary: 提供訂單計費、發票與退款處理能力
owner: team-finance
status: active
tags:
  - billing
  - finance
---

# Billing API

## Purpose
說明這個 repo 解決什麼問題。

## Scope
列出負責範圍與不負責範圍。

## Architecture
描述主要模組與資料流。

## Project Structure
列出重要目錄與入口檔。

## Runbook
列出 install、dev、test 等指令。

## Interfaces
列出 API、event、cron、webhook 等介面。

## Dependencies
列出資料庫、外部服務與第三方平台。

## Notes
列出限制、風險與待補事項。
```

## 5. 驗證規則

- `schema_version` 必須為整數。
- `repo_id` 應為 kebab-case。
- `summary` 應限制在單句，避免長段落。
- `commands` 不可出現空值。
- `entrypoints` 中列出的路徑應存在於 repo。
- `docs` 中列出的路徑應存在於 repo。
- README 的 H2 章節順序應與標準骨架一致；若不適用，可保留標題並標示 `N/A`。

## 6. README Agent 執行規範

當 `101-readme-agent` 被啟用時，應遵守：
- 先掃描 repo 現況，再決定是 `metadata_only`、`normalize`、`rewrite` 或 `manifest_plus_readme`
- 不得為了滿足 schema 而臆測事實欄位
- 若欄位缺失，應回報 `unresolved_fields`
- 若 repo 已有更正式的來源檔，README 只能摘要，不可覆蓋其事實

## 7. 導入建議

### 7.1 單 repo
- 先補 README front matter
- 再整理固定章節

### 7.2 多 repo
- 先建立 `repo.manifest.yaml`
- 之後由 CI 驗證 schema
- 最後讓 README 摘要 manifest

### 7.3 排程 Action
- 先讀 `repo.manifest.yaml`
- 若不存在，再 fallback 到 README front matter
- 最後才讀 README 章節內容

## 8. 參考範本

- Manifest 範本：`docs/policies/repo.manifest.example.yaml`
