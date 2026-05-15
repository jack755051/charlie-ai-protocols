# CAP Documentation Index

> 本目錄存放 CAP（Charlie's AI Protocols）的工程文件。
>
> **目前定位 SSOT**：先看 [`CAP-POSITIONING.md`](CAP-POSITIONING.md)。
> CAP 現在定位為 AI CLI governance / observability layer，不再以
>「比 Claude Code / Codex 更會完成 coding task」作為產品目標。
>
> **衝突時以此順序為準**：
> [`CAP-POSITIONING.md`](CAP-POSITIONING.md) →
> [`PLATFORM-GOAL.md`](PLATFORM-GOAL.md) →
> [`IMPLEMENTATION-ROADMAP.md`](IMPLEMENTATION-ROADMAP.md) →
> boundary / schema 文件。

## 一、入口導覽（按需求查）

| 我想… | 看這份 |
|---|---|
| 先確認 CAP 現在到底是什麼 / 不是什麼 | [CAP-POSITIONING.md](CAP-POSITIONING.md) |
| 知道 CAP 整體目標與設計理念 | [PLATFORM-GOAL.md](PLATFORM-GOAL.md) |
| 看完整架構與模組關係 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 找 P0–P6 任一概念的 SSOT 在哪個檔 / 哪個 schema | [ARCHITECTURE.md §P0–P6 Runtime Module Map](ARCHITECTURE.md#p0p6-runtime-module-map-convergence-checkpoint-2) |
| 查舊 P0-P10 工程 backlog / release gate 歷史 | [MISSING-IMPLEMENTATION-CHECKLIST.md](MISSING-IMPLEMENTATION-CHECKLIST.md) |
| 看 release tag 對應的功能 | [RELEASE-NOTES.md](RELEASE-NOTES.md) |
| 看收斂後的開發路線 | [IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md) |
| 決定 dogfood 要測 readiness / preflight / observability 哪一層 | [DOGFOOD-PROFILES.md](DOGFOOD-PROFILES.md) |
| 只跑某一層 smoke，不想每次跑完整 release gate | [`scripts/workflows/smoke-layer.sh`](../../scripts/workflows/smoke-layer.sh) |
| 操作 / debug 一個正在跑或剛結束的 workflow run（logs / watch / inspect） | [RUN-OBSERVABILITY-GUIDE.md](RUN-OBSERVABILITY-GUIDE.md) |
| 想知道 run observability 為什麼這樣設計（planning / phase roadmap） | [RUN-OBSERVABILITY-MEMO.md](RUN-OBSERVABILITY-MEMO.md) |
| Phase 5 後三項（stderr capture / `run -d` / TUI）的 deferred 設計討論 | [RUN-OBSERVABILITY-PHASE-5-LATER-MEMO.md](RUN-OBSERVABILITY-PHASE-5-LATER-MEMO.md) |
| 整理安裝後 Claude Code / Codex provider readiness 與首次登入導引 | [PROVIDER-ONBOARDING-MEMO.md](PROVIDER-ONBOARDING-MEMO.md) |
| 追 provider readiness 實作任務 | [PROVIDER-READINESS-TASKS.md](PROVIDER-READINESS-TASKS.md) |
| Karpathy guardrails / 其他 advisory skill 整合到 CAP 的 staged 計畫 | [KARPATHY-GUIDELINES-INTEGRATION-MEMO.md](KARPATHY-GUIDELINES-INTEGRATION-MEMO.md) |
| Role（可執行角色）vs Skill（掛載型 guardrail）的分離模型與 schema 演進路徑 | [ROLE-SKILL-REGISTRY-MODEL-MEMO.md](ROLE-SKILL-REGISTRY-MODEL-MEMO.md) |

## 二、凍結 / 歷史文件

以下文件保留作為歷史依據，不代表目前主線：

| 文件 | 狀態 |
|---|---|
| [COMPONENT-FAST-PATH-MEMO.md](COMPONENT-FAST-PATH-MEMO.md) | runtime removed; evidence memo retained |
| [COMPONENT-REPO-TEMPLATE-CONTRACT.md](COMPONENT-REPO-TEMPLATE-CONTRACT.md) | profile-specific contract; not CAP core |
| [PROVIDER-PARITY-E2E.md](PROVIDER-PARITY-E2E.md) | historical release gate pattern; not active default dogfood |
| [KARPATHY-GUIDELINES-INTEGRATION-MEMO.md](KARPATHY-GUIDELINES-INTEGRATION-MEMO.md) | deferred advisory skill expansion |

## 三、邊界備忘錄（Boundary memos）

跨模組責任分工的 SSOT。新增 capability、調整 storage layout、或變更執行流程之前，先讀對應 boundary。

| 主題 | 文件 |
|---|---|
| Project Constitution vs Task Constitution 5-surface 分流 | [CONSTITUTION-BOUNDARY.md](CONSTITUTION-BOUNDARY.md) |
| Supervisor Orchestrator envelope 的 producer / consumer / storage | [SUPERVISOR-ORCHESTRATION-BOUNDARY.md](SUPERVISOR-ORCHESTRATION-BOUNDARY.md) |
| Orchestration four-part snapshot storage layout | [ORCHESTRATION-STORAGE-BOUNDARY.md](ORCHESTRATION-STORAGE-BOUNDARY.md) |
| Shell executor vs Python additive layer 分層 | [EXECUTION-LAYERING.md](EXECUTION-LAYERING.md) |

## 四、執行層參考（Reference）

| 主題 | 文件 |
|---|---|
| Skill registry / runtime adapter 設計 | [SKILL-RUNTIME-ARCHITECTURE.md](SKILL-RUNTIME-ARCHITECTURE.md) |
| Design source ingestion 流程 | [DESIGN-SOURCE-RUNTIME.md](DESIGN-SOURCE-RUNTIME.md) |

## 五、政策索引（Policies）

| 主題 | 文件 |
|---|---|
| Shell fixture 撰寫與 `pipefail + grep -q` 陷阱 | [policies/test-fixture-authoring.md](../../policies/test-fixture-authoring.md) |

## 六、品質報告（Provider parity）

歷史 fresh-run 對照報告，作為 release gate baseline 紀錄。一次性 findings / runbook 已移到 `development-records/`，一般開發不需讀；做 cross-provider regression 比對時才看。

| 主題 | 文件 |
|---|---|
| Provider parity e2e 範本 | [PROVIDER-PARITY-E2E.md](PROVIDER-PARITY-E2E.md) |
| v0.21.2 parity findings | [provider-parity-findings-v0.21.2.md](../../development-records/findings/provider-parity-findings-v0.21.2.md) |
| v0.21.5 fresh provider e2e baseline | [provider-parity-fresh-e2e-v0.21.5.md](../../development-records/dogfood/provider-parity-fresh-e2e-v0.21.5.md) |

## 七、新增文件規則

收斂後請避免重新發散。新增文件前先評估：

- **某次 release 的歷史紀錄**：直接寫進 [RELEASE-NOTES.md](RELEASE-NOTES.md) 對應 tag 段落，不開新檔。
- **跨模組責任邊界**：開新的 `*-BOUNDARY.md`，並更新本 index 第二節。
- **執行層 / runtime 架構說明**：歸到第三節 reference 區，更新 index。
- **品質 / parity / 一次性 e2e 報告**：歸到 [`development-records/`](../../development-records/)，必要時只在本 index 第四節保留連結。
- **使用者導引**：寫進 root [README.md](../../README.md)，不要寫進 docs/cap。
- **測試入口**：分層 smoke 入口維護在 [`scripts/workflows/smoke-layer.sh`](../../scripts/workflows/smoke-layer.sh)；完整 release gate 維持 [`scripts/workflows/smoke-per-stage.sh`](../../scripts/workflows/smoke-per-stage.sh)。
- **新 profile / template / component generator**：預設不新增；若真的需要，先寫 decision record 說明為什麼不應直接用 Claude Code / Codex。

文件互相連結時，盡量單向（e.g., README → docs/cap/X，而非 X → README → X）。本 index 是雙向 hub，是唯一允許的「指出去再指回來」節點。
