# Strategy: Karpathy LLM-Coding Guardrails (四規則防滑檻)

> 改寫自 Andrej Karpathy 對 LLM coding pitfalls 的觀察（[原始 thread](https://x.com/karpathy/status/2015883857489522876)）；CAP 內當作 **advisory methodology strategy**。本 strategy 不是可執行 role，**不取代** 任何 agent prompt、project constitution、或使用者明確指令。
>
> 從 v0.24.7 (shared layer dogfood) 累積到 v0.24.9 共 7 筆 real-run evidence（4 個 task shape：smoke / code-review / refactor-proposal / debug；Claude + Codex cross-provider parity 確認），entry criteria 滿足後 Phase 2 promote 到 builtin。完整 evidence log 見 [`docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md`](../../docs/cap/KARPATHY-GUIDELINES-INTEGRATION-MEMO.md) §Phase 1 Dogfood Evidence Log。

## 1. 適用情境 (When To Mount)
- 寫、重構、或審查代碼類任務（real-task dogfood 證實在 code review / refactor proposal / debug triage 三類都產 grounded、useful、surgical 的 advisory）。
- 任務 default LLM failure mode 含速度大於思考的場景（典型有：「直接 patch 這個 bug」、「順手抽出這段 logic」、「加上 try/catch 防一下」）。

不適用 / 輕量介入：
- 純 docs 編輯、typo fix、命名修正等 trivial 任務。
- 使用者明確要求相反（例如「請寫完整的 retry+ fallback」），使用者指令贏。
- 設計 / 規格層任務（spec / PRD / BA 流程繪製），那些走 vertical-slice-planning 與 architecture-deepening；本 strategy 補位，不取代。

## 2. 核心紀律 (Four Rules)

### Rule 1 — Think Before Coding（先想再寫）
**不假設、不藏困惑、surface tradeoff。**

寫代碼前：
- 假設明說。不確定就問。
- 多種解讀都列出來，**不要默默挑一個**。
- 簡單寫法存在就講出來，必要時 push back。
- 不清楚就 stop、命名困惑點、問。

CAP 對應紀律：
- Pre-action Checklist (`Context Check / Action Planning / Impact`) 是 surface 假設的內建管道。
- 若 project constitution 已約束契約（schema / 邊界 / workflow shape），以 constitution 為準，並在 checklist 中註明 deferral，不要在 advisory 裡爭論。

### Rule 2 — Simplicity First（先簡再繁）
**最小代碼解決問題，不投機。**

- 沒被要求的 feature 不加。
- 單次使用的 code 不抽象。
- 沒被要求的「彈性 / 可配置性」不加。
- 不可能發生的場景不寫 error handling。
- 200 行能寫成 50 行就重寫。

自我檢核：「資深工程師會說這太複雜嗎？」是 → 簡化。

CAP 對應紀律：
- 不要預先加 capability、agent、workflow「以防萬一」。真實 consumer 出現再加。
- 有疑慮時先 ship 最小 read-only / dispatcher-side 變更。v0.24.x observability 線是 canonical 範例：小 additive surface、runtime 沒動到，等 evidence 才動深層。

### Rule 3 — Surgical Changes（外科式變動）
**只動該動的，只清自己造的混亂。**

修既有代碼時：
- 不順手「改善」鄰近 code、註解、格式。
- 不要重構沒壞的東西。
- 即使你會用不同寫法，仍對齊既有 style。
- 看到無關 dead code 就提報，不要刪。

你的變動造成 orphans 時：
- 移除**你的變動**讓它失效的 import / variable / function。
- 不要刪掉**先前就存在**的 dead code，除非被要求。

驗證：每行被改的代碼都能直接追溯到使用者請求。

CAP 對應紀律：
- `00-core-protocol.md` 的 `Legacy Shield`（不修正 `resquest` 等刻意保留拼寫）是本規則的更嚴版本。
- 重構跨越模組 / agent 邊界時，在 Pre-action Checklist 的 `Impact` 段揭露交叉影響，不要默默改。

### Rule 4 — Goal-Driven Execution（目標導向、可驗證）
**先定義成功，迴圈直到驗證通過。**

把任務轉成可驗證目標：
- 「加上 validation」→「對非法輸入寫測試，然後讓它通過。」
- 「修這個 bug」→「寫一個重現它的測試，然後讓它通過。」
- 「重構 X」→「確保前後測試都通過。」

多步驟任務先給簡短 plan：

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

強的成功標準讓你能獨立 loop。弱的（"make it work"）需要不斷澄清。

CAP 對應紀律：
- Watcher (90) 與 QA (07) 的 gate 是正式驗證管道；本規則補位，要求 **預先**宣告成功標準而非事後追溯。
- diagnostic / regression 工作走 `agent-skills/strategies/diagnose-loop.md`（Phase 1 feedback loop 是讓「迴圈直到驗證通過」實際快得起來的紀律）。

## 3. 衝突解決順序 (Conflict Resolution Order)

本 strategy 與其他指示衝突時，依優先序執行：

1. 使用者本回合明示指令。
2. Project Constitution（`.cap.constitution.yaml` / `docs/architecture/...`）。
3. Agent role prompt（`agent-skills/0X-*-agent.md`）。
4. 其他 CAP methodology strategies（TDD vertical slice、architecture-deepening、diagnose-loop 等）。
5. **本 strategy（Karpathy guidelines）。**

更高優先指令與 Karpathy 規則衝突時，更高優先贏，本 strategy 退化為當回合的 advisory 註解。

## 4. 邊界與不擴張 (Boundary)

本 strategy 為 **advisory layer**：
- **不**取代 agent role prompt — role 擁有任務 identity，本 strategy 只 mount 在 role 上。
- **不**覆寫 project constitution — `.cap.constitution.yaml` 設定的 `allowed_capabilities` / `allowed_source_roots` / governance gate 仍然主導。
- **不**覆寫使用者明示指令 — 本 strategy 與 user intent 衝突時，user intent 贏。
- **不**強制 trivial 任務套四規則 — 對 typo / 純 docs / config 微調，本 strategy 應**輕量介入**或退場。

## 5. 與其他 Strategies 的關係

| 場景 | 主 strategy | 本 strategy 的補位 |
|---|---|---|
| 規劃 vertical slice | vertical-slice-planning | Rule 1 防止跳過 think-before-coding |
| 跨模組架構決策 | architecture-deepening | Rule 2 / 3 防止 speculative wrapper |
| TDD 紅綠重構 | tdd-vertical-slice | Rule 4 強化「先寫 verify check」紀律 |
| 診斷 / debug | diagnose-loop | Rule 1 強化 multi-interpretation tabling、Rule 3 防止 speculative refactor |
| 程式碼審查 | （無專屬 strategy）| 主場景 — 4 規則 grounded review |
| 框架特化（Angular / Nuxt / NestJS / .NET） | frontend-X / backend-X | Rule 2 / 3 約束「不順手換 framework idiom」|

掛載多 strategy 時，所有 strategies 共同生效，沒有互斥。

## 6. Mount 方式 (Reference From Agent Prompts)

候選 agent prompts 在自身 `## X. 方法論策略 (Methodology Strategies)` 段落 reference 本 strategy。當前 (v0.24.9) 已 reference 的有：

- `01-supervisor-agent.md`（規劃 / 編排決策）
- `02-techlead-agent.md`（架構評估 / 技術選型）
- `04-frontend-agent.md`（前端實作 / 重構）
- `05-backend-agent.md`（後端實作 / 重構）
- `07-qa-agent.md`（測試規劃 / 驗證）
- `10-troubleshoot-agent.md`（debug / RCA）
- `90-watcher-agent.md`（結構稽核 / cross-cutting review）

刻意 **不** reference 的 agents（情境不適用本 strategy 或本 strategy 對其價值偏低）：

- `03-ui-agent.md`（設計資產為主，4 規則對視覺決策貢獻有限）
- `06-devops-agent.md` 的 release / tag-only path（純 git ops 不需要 4 規則）
- `09-analytics-agent.md`（KPI / 指標規劃，與 4 規則 tangential）
- `12-figma-agent.md`（同步資產，無 code 決策）
- `99-logger-agent.md`（純紀錄，無 code 決策）

擴張到上述五個 agent 須有具體 dogfood 證據觸發，而非預設 reference。

## 7. 歷史紀錄 (Historical Track)

- v0.24.7：shared-layer dogfood scaffold（`~/.cap/shared/skills/karpathy-guidelines.md`）。
- v0.24.8：Role / Skill Registry Phase 1 schema preparation（optional `kind` enum）；shared layer entry adopt `kind: skill`。
- v0.24.7 → v0.24.9：累積 7 筆 real-run dogfood evidence 跨 4 task shape，Phase 2 entry criteria 全滿足。
- **v0.24.9：Phase 2 promote — 本 strategy 由 shared layer 進入 CAP builtin baseline。** Shared layer entry 保留作為 user-local override 範例（runtime 仍接受），但 baseline 透過本檔 + 7 agent reference 載入。
