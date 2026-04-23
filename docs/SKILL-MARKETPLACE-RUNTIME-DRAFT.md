# Skill Marketplace 與 Runtime Binding 草案

> 本文件是 CAP 下一階段的架構草案。
> 目標是支援第三方匯入 / 匯出 agent-skill，同時避免 workflow 因 skill 缺失而失效。

## 核心原則

- **workflow 只描述流程語意**：`step`、`needs`、`gate`、`fail route`、`governance`
- **capability 是流程與實作之間的穩定介面**
- **agent-skill 是可插拔實作，不是 workflow 的直接依賴**

一句話：

- `workflow` 是地圖
- `capability` 是職缺
- `agent-skill` 是可替換的人員

## 為什麼要改

目前 runtime 仍偏向早綁定：在建 plan 時就把 capability 直接解析成固定 agent。

這對固定團隊有效，但若未來 skill 可由其他使用者匯入 / 匯出，就會出現兩個問題：

1. 缺 skill 會導致 workflow 無法完整建 plan
2. marketplace 的 skill 變動會直接影響 workflow 可讀性與可審核性

正確做法是把流程建構與 skill 綁定拆成兩階段。

## 未來執行模型

### 1. Build

- 只讀取 workflow 與 capability contract
- 驗證 phase / gate / governance 是否合理
- **不要求 skill 一定存在**

輸出：`semantic plan`

### 2. Bind / Preflight

- 依 skill registry 將 capability 綁到可用 skill
- 若找不到 skill，標記為：
  - `required_unresolved`
  - `optional_unresolved`
  - `fallback_available`
- 依 binding policy 決定是否：
  - `halt`
  - `substitute`
  - `manual`

輸出：`binding report`

### 3. Execute

- 只有在 preflight 可接受時才進入正式執行
- handoff / governance / watcher / logger 仍由 CAP 自己的 schema 管理

## 設計結論

未來若 skill 缺失：

- **workflow 應該仍可載入、展示、審核**
- 只有 execution plan 進入 `degraded` 或 `blocked`
- 不應因為 marketplace 缺 skill 就讓 workflow 壞掉

## 與 LangChain / LangGraph 的關係

- `LangChain` 不適合直接取代 CAP 的 workflow 治理模型
- `LangGraph` 可以作為 runtime backend
- **workflow / capability / handoff / governance 仍應由 CAP 自己維持 SSOT**

結論：

- CAP schema 負責規則與治理
- LangGraph 可負責圖執行、狀態流轉、節點呼叫與回圈控制
- LangGraph 不應取代 workflow schema 本身

## 本 repo 內的 draft 檔案

- `.cap.skills.example.yaml`
- `schemas/skill-manifest.schema.yaml`
- `schemas/skill-registry.schema.yaml`
- `schemas/unresolved-binding.schema.yaml`
- `engine/runtime_binder.py`

## 本地試跑方式

1. 複製範例 registry：

```bash
cp .cap.skills.example.yaml .cap.skills.yaml
```

2. 查看 workflow 的 semantic + binding 狀態：

```bash
cap workflow plan version-control-private
cap workflow bind version-control-private
```

## Draft 範圍

本草案先做到：

- workflow semantic plan 與 skill binding 分離
- skill registry 可缺省
- capability 缺 skill 時輸出 `unresolved binding report`
- fallback 與 missing policy 先以 draft 形式存在

本草案**尚未**做到：

- marketplace 遠端拉取
- 真正的 registry 安裝 / 升級 CLI
- dispatch 前自動 materialize handoff ticket
- LangGraph backend 實作
