# CAP Documentation Index

> 本目錄存放 CAP（Charlie's AI Protocols）的 **active** 工程文件。
>
> **目前定位 SSOT**：先看 [`CAP-POSITIONING.md`](CAP-POSITIONING.md)。
> CAP 現在定位為 AI CLI governance / observability layer，不再以
>「比 Claude Code / Codex 更會完成 coding task」作為產品目標。
>
> **衝突時以此順序為準**：
> [`CAP-POSITIONING.md`](CAP-POSITIONING.md) →
> [`PLATFORM-GOAL.md`](PLATFORM-GOAL.md) →
> [`CAP-LEAN-ROADMAP.md`](CAP-LEAN-ROADMAP.md) →
> 個別 boundary / contract / schema 文件。

## 一、入口導覽（按需求查）

| 我想… | 看這份 |
|---|---|
| 先確認 CAP 現在到底是什麼 / 不是什麼 | [CAP-POSITIONING.md](CAP-POSITIONING.md) |
| 知道 CAP 整體目標與設計理念 | [PLATFORM-GOAL.md](PLATFORM-GOAL.md) |
| 看收斂重構任務清單 | [CAP-LEAN-ROADMAP.md](CAP-LEAN-ROADMAP.md) |
| 看完整架構與模組關係 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 找 P0–P6 任一概念的 SSOT 在哪個檔 / 哪個 schema | [ARCHITECTURE.md §P0–P6 Runtime Module Map](ARCHITECTURE.md#p0p6-runtime-module-map-convergence-checkpoint-2) |
| 看 release tag 對應的功能 | [RELEASE-NOTES.md](RELEASE-NOTES.md) |
| 操作 / debug 一個正在跑或剛結束的 workflow run（logs / watch / inspect） | [RUN-OBSERVABILITY-GUIDE.md](RUN-OBSERVABILITY-GUIDE.md) |
| 整理安裝後 Claude Code / Codex provider readiness 與首次登入導引 | [PROVIDER-ONBOARDING-MEMO.md](PROVIDER-ONBOARDING-MEMO.md) |
| 追 provider readiness 實作任務 | [PROVIDER-READINESS-TASKS.md](PROVIDER-READINESS-TASKS.md) |
| 知道 AI step 的 result enum / 結束契約怎麼寫 | [AI-STEP-RESULT-CONTRACT.md](AI-STEP-RESULT-CONTRACT.md) |

## 二、邊界備忘錄（Boundary memos）

跨模組責任分工的 SSOT。新增 capability、調整 storage layout、或變更執行流程之前，先讀對應 boundary。

| 主題 | 文件 |
|---|---|
| Project Constitution vs Task Constitution 5-surface 分流 | [CONSTITUTION-BOUNDARY.md](CONSTITUTION-BOUNDARY.md) |
| Shell executor vs Python additive layer 分層 | [EXECUTION-LAYERING.md](EXECUTION-LAYERING.md) |

## 三、政策索引（Policies）

| 主題 | 文件 |
|---|---|
| Shell fixture 撰寫與 `pipefail + grep -q` 陷阱 | [policies/test-fixture-authoring.md](../../policies/test-fixture-authoring.md) |
| Replay artifact contract | [policies/replay-contract.md](../../policies/replay-contract.md) |
| Runtime promote 政策 | [policies/runtime-promote.md](../../policies/runtime-promote.md) |
| Agent-skill baseline | [policies/agent-skills-baseline.md](../../policies/agent-skills-baseline.md) |

## 四、歷史 / Deferred / 設計記錄

舊版設計、deferred memo、已退出 active runtime 的 profile / 工具紀錄等，2026-05-15 lean prune 後統一搬到：

```text
development-records/archive/docs-cap/
```

需要 cite 歷史背景、或追 deferred 設計脈絡時再去讀。日常開發不需要打開。

代表性檔案（節錄）：

- `COMPONENT-FAST-PATH-MEMO.md` — component-fast runtime evidence + reopen criteria
- `COMPONENT-REPO-TEMPLATE-CONTRACT.md` — profile-specific contract
- `KARPATHY-GUIDELINES-INTEGRATION-MEMO.md` — Karpathy guardrails 整合計畫
- `ROLE-SKILL-REGISTRY-MODEL-MEMO.md` — Phase 5 role + attached-skill 設計
- `SKILL-RUNTIME-ARCHITECTURE.md` — skill registry / runtime adapter 設計
- `SUPERVISOR-ORCHESTRATION-BOUNDARY.md` — supervisor envelope 5-surface 分流
- `ORCHESTRATION-STORAGE-BOUNDARY.md` — orchestration snapshot storage layout
- `REPLAY-CONTRACT-DESIGN.md` + `REPLAY-USER-GUIDE.md` — replay 契約與操作
- `PROMOTE-LIFECYCLE.md` — promote 操作指南
- `DESIGN-SOURCE-RUNTIME.md` — design source ingest 流程
- `RUN-OBSERVABILITY-MEMO.md` + `RUN-OBSERVABILITY-PHASE-5-LATER-MEMO.md` — observability 設計脈絡 + Phase 5 deferred 設計
- `AGENT-SKILLS-CUSTOMIZATION.md` — 進階 skill 自訂指南
- `H2-` / `H3-` / `H4-` / `P9-` design memos — replay / drift / source resolver 設計記錄
- `COST-OPTIMIZATION-MEMO.md` — cost telemetry 歷史脈絡（觸發 lean 重構）
- `IMPLEMENTATION-ROADMAP.md` — 舊 phase roadmap，已由 CAP-LEAN-ROADMAP 取代
- `DOGFOOD-PROFILES.md` — 舊 dogfood profile 對照
- `MISSING-IMPLEMENTATION-CHECKLIST.md` — 舊 P0-P10 backlog 紀錄

## 五、新增文件規則

收斂後請避免重新發散。新增文件前先評估：

- **某次 release 的歷史紀錄**：直接寫進 [RELEASE-NOTES.md](RELEASE-NOTES.md) 對應 tag 段落，不開新檔。
- **跨模組責任邊界**：開新的 `*-BOUNDARY.md`，並更新本 index 第二節。
- **執行層 / runtime 架構說明**：能寫進 ARCHITECTURE.md 的就寫進去；獨立文件門檻提高。
- **品質 / parity / 一次性 e2e 報告**：歸到 [`development-records/`](../../development-records/)，**不要**新增到 docs/cap。
- **deferred / 歷史 / design memo**：歸到 [`development-records/archive/docs-cap/`](../../development-records/archive/docs-cap/) 或 `development-records/closeouts/`，不要回流 docs/cap。
- **使用者導引**：寫進 root [README.md](../../README.md)，不要寫進 docs/cap。
- **測試入口**：分層 smoke 入口維護在 [`scripts/workflows/smoke-layer.sh`](../../scripts/workflows/smoke-layer.sh)；完整 release gate 維持 [`scripts/workflows/smoke-per-stage.sh`](../../scripts/workflows/smoke-per-stage.sh)。
- **新 profile / template / component generator**：預設不新增；若真的需要，先寫 decision record 說明為什麼不應直接用 Claude Code / Codex。

文件互相連結時，盡量單向（e.g., README → docs/cap/X，而非 X → README → X）。本 index 是雙向 hub，是唯一允許的「指出去再指回來」節點。

## 六、判斷標準（一句話版）

- 留在 docs/cap：**現在操作 CAP 必須知道**。
- 移到 development-records：**以前為什麼這樣設計** / **曾經做過什麼 dogfood** / **未來可能再開的 deferred design**。
