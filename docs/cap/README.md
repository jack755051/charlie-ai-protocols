# CAP Documentation Index

> 本目錄存放 CAP（Charlie's AI Protocols）的工程文件。為避免每次掃整個 `docs/cap/`，請依以下入口找對應文件。
>
> **單一事實來源 (SSOT)**：當前進度看 [`MISSING-IMPLEMENTATION-CHECKLIST.md`](MISSING-IMPLEMENTATION-CHECKLIST.md)，架構看 [`ARCHITECTURE.md`](ARCHITECTURE.md)，邊界看對應 `*-BOUNDARY.md`。其他文件如有衝突，以這三類為準。

## 一、入口導覽（按需求查）

| 我想… | 看這份 |
|---|---|
| 知道 CAP 整體目標與設計理念 | [PLATFORM-GOAL.md](PLATFORM-GOAL.md) |
| 看完整架構與模組關係 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 知道目前實作到哪、哪些待做 | [MISSING-IMPLEMENTATION-CHECKLIST.md](MISSING-IMPLEMENTATION-CHECKLIST.md) |
| 看 release tag 對應的功能 | [RELEASE-NOTES.md](RELEASE-NOTES.md) |
| 看開發路線圖（按 Phase / 階段） | [IMPLEMENTATION-ROADMAP.md](IMPLEMENTATION-ROADMAP.md) |

## 二、邊界備忘錄（Boundary memos）

跨模組責任分工的 SSOT。新增 capability、調整 storage layout、或變更執行流程之前，先讀對應 boundary。

| 主題 | 文件 |
|---|---|
| Project Constitution vs Task Constitution 5-surface 分流 | [CONSTITUTION-BOUNDARY.md](CONSTITUTION-BOUNDARY.md) |
| Supervisor Orchestrator envelope 的 producer / consumer / storage | [SUPERVISOR-ORCHESTRATION-BOUNDARY.md](SUPERVISOR-ORCHESTRATION-BOUNDARY.md) |
| Orchestration four-part snapshot storage layout | [ORCHESTRATION-STORAGE-BOUNDARY.md](ORCHESTRATION-STORAGE-BOUNDARY.md) |
| Shell executor vs Python additive layer 分層 | [EXECUTION-LAYERING.md](EXECUTION-LAYERING.md) |

## 三、執行層參考（Reference）

| 主題 | 文件 |
|---|---|
| Skill registry / runtime adapter 設計 | [SKILL-RUNTIME-ARCHITECTURE.md](SKILL-RUNTIME-ARCHITECTURE.md) |
| Design source ingestion 流程 | [DESIGN-SOURCE-RUNTIME.md](DESIGN-SOURCE-RUNTIME.md) |

## 四、品質報告（Provider parity）

歷史 fresh-run 對照報告，作為 release gate baseline 紀錄。一般開發不需讀；做 cross-provider regression 比對時才看。

| 主題 | 文件 |
|---|---|
| Provider parity e2e 範本 | [PROVIDER-PARITY-E2E.md](PROVIDER-PARITY-E2E.md) |
| v0.21.2 parity findings | [PROVIDER-PARITY-FINDINGS-v0.21.2.md](PROVIDER-PARITY-FINDINGS-v0.21.2.md) |
| v0.21.5 fresh provider e2e baseline | [PROVIDER-PARITY-FRESH-E2E-V0.21.5.md](PROVIDER-PARITY-FRESH-E2E-V0.21.5.md) |

## 五、新增文件規則

收斂後請避免重新發散。新增文件前先評估：

- **某次 release 的歷史紀錄**：直接寫進 [RELEASE-NOTES.md](RELEASE-NOTES.md) 對應 tag 段落，不開新檔。
- **跨模組責任邊界**：開新的 `*-BOUNDARY.md`，並更新本 index 第二節。
- **執行層 / runtime 架構說明**：歸到第三節 reference 區，更新 index。
- **品質 / parity / 一次性 e2e 報告**：歸到第四節 quality reports 區，命名帶版本前綴。
- **使用者導引**：寫進 root [README.md](../../README.md)，不要寫進 docs/cap。

文件互相連結時，盡量單向（e.g., README → docs/cap/X，而非 X → README → X）。本 index 是雙向 hub，是唯一允許的「指出去再指回來」節點。
