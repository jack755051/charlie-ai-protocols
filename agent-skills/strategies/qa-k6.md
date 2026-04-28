# Strategy: Performance Testing with k6 (v1.0)

> 本文件定義使用 Grafana k6 進行負載與壓力測試的專屬實作標準。AI 必須模擬真實使用者行為，並產出具備統計意義與阻斷能力的性能報告。

## 1. 測試情境與壓力模型 (Test Scenarios)

> **⚠️ 硬性規定：嚴禁單一頻率測試，必須根據任務目標定義壓力曲線。**

- **負載測試 (Load Test)**：模擬預期正常流量，確認系統在 SLA 範圍內的反應速度與穩定性。
- **壓力測試 (Stress Test)**：持續增加虛擬用戶 (VUs) 直至系統崩潰，明確找出系統的「臨界點 (Breaking Point)」。
- **滲透測試 (Soak Test)**：長時間（如 1 小時以上）維持中高負載，專門稽核記憶體洩漏 (Memory Leak) 或資料庫連線池 (DB Pool) 溢出問題。

## 2. 硬性實作規範 (Implementation Standards)

- **腳本模組化架構**：
  - `data/`：存放測試資料（如 CSV 用戶帳密、產品 UUID 列表），禁止硬編碼。
  - `scenarios/`：將業務流程（如 Login, Search, Checkout）封裝為獨立函式，便於複用。
- **指標門檻 (Thresholds) 阻斷機制**：所有腳本必須包含硬性通過標準，否則 CI/CD 應判定失敗：
  - **回應時間**：`http_req_duration: ['p(95)<500']` (95% 的請求必須低於 500ms)。
  - **錯誤率**：`http_req_failed: ['rate<0.01']` (失敗率必須低於 1%)。
- **虛擬用戶行為 (VU Logic)**：
  - **模擬思考時間**：嚴禁無腦死迴圈。腳本步驟間必須包含 `sleep()` 以模擬人類真實操作間隔。
  - **隨機化**：測試數據選取應具備隨機性，避免因資料庫緩存 (Cache) 導致測試結果失真。

## 3. 環境變數與安全標籤 (Environment & Safety)

- **API URL 隔離**：目標主機地址必須從環境變數讀取，**絕對禁止**在腳本中寫死 IP 或 Domain。
- **識別標頭 (Audit Header)**：所有測試請求標頭必須包含 `User-Agent: k6-load-test`，以便在日誌中與真實惡意攻擊區分，避免觸發 WAF 自動封鎖。

---

## 4. 專案慣例與遺留守護 (Legacy & Conventions)

- **拼寫絕對守護**：若 API Endpoint 存在歷史拼寫錯誤（例如 `/api/v1/resquest-log`），測試腳本**必須沿用錯誤拼寫**，嚴禁擅自修正導致測試失敗。