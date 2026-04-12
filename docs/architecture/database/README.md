# Database Design & SSOT (單一事實來源)

## 1. 資料夾定位
本資料夾存放整個專案的資料庫設計規格。它是系統開發中關於資料結構的 **唯一事實來源 (Single Source of Truth)**。

## 2. 角色權限邊界
- **寫入者 (Owner)**：`02 SA Agent (系統架構師)`。只有 SA 擁有修改本目錄下規格文件的權限。
- **讀取者 (Consumer)**：
    - `05 Backend Agent`：根據 `schema.md` 實作 Entity 與 Migration。
    - `04 Frontend Agent`：參考欄位約束（如長度、必填）進行 UI 表單驗證。
- **稽核者 (Auditor)**：`90 Watcher Agent`。負責比對實作代碼是否偏離此處定義的規格。

## 3. 核心文件說明
- **`schema.md`**：定義所有 Table/Collection 的欄位、型別、索引、外鍵約束及樂觀併發 (Version) 欄位。
- **`er-diagram.md`** (選配)：存放以 Mermaid 語法繪製的實體關聯圖。

## 4. 變更協議
1. 若實作過程中發現 Schema 設計不合理，後端 Agent **嚴禁自行修改代碼**。
2. 必須回報 **01 PM**，由 PM 重新發派任務給 **02 SA** 修改本目錄下的規格。
3. 規格更新後，由 **90 Watcher** 重新稽核，確保全線同步。

---
⚠️ **警告**：嚴禁在沒有更新 `schema.md` 的情況下直接執行資料庫 Migration 變更。