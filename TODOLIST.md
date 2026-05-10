# CAP Platform TODO

> 本檔只保留「下一步該做什麼」。歷史完成紀錄、逐批工程細節與 release evidence 不再複製到這裡，避免和 `docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md`、`docs/cap/RELEASE-NOTES.md` 形成三份平行事實來源。

## SSOT

| 需求 | 來源 |
|---|---|
| 目前完成狀態 / 工程待辦 | [docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md](docs/cap/MISSING-IMPLEMENTATION-CHECKLIST.md) |
| 產品路線與 Phase / P 對照 | [docs/cap/IMPLEMENTATION-ROADMAP.md](docs/cap/IMPLEMENTATION-ROADMAP.md) |
| 架構與模組邊界 | [docs/cap/ARCHITECTURE.md](docs/cap/ARCHITECTURE.md) |
| Release tag 對應功能 | [docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md) |
| 文件入口 | [docs/cap/README.md](docs/cap/README.md) |

## Current Focus

1. **Project Constitution workflow output contract**
   - 目標：讓 `schemas/workflows/project-constitution.yaml` 直接輸出 Markdown + JSON artifact。
   - 理由：`cap project constitution` runner 已具備 validation / snapshot / promote；剩下要消除「runner 從自由文字抽 JSON」這條多餘路徑。

2. **Supervisor Orchestrator producer**
   - 目標：實作 supervisor prompt builder + structured output parser，產出可驗證的 Supervisor Orchestration Envelope。
   - 理由：envelope schema、helper、snapshot writer、compile entry、release-gate e2e 已落地；缺的是真正 producer，不是更多 parallel contract。

3. **Envelope to runtime consumption**
   - 目標：打通 Envelope → Type C ticket → runtime dispatcher 的最小閉環。
   - 理由：目前 `failure_routing` 可解析但 production runtime 尚未完整消費；需避免誤讀成 supervisor 已能控制 retry / route_back / escalate。

4. **Role / Skill attachment dogfood**
   - 目標：等真實 user-imported role / guardrail attachment 需求出現，再設計 Phase 4 / 5 attachment。
   - 理由：v0.24 已完成 registry schema 與 resolver 基礎；沒有真實用例前不再預先擴張。

5. **Deferred work remains deferred**
   - H5 / H6 / H7 replay precision、detached runtime、publish workflow、TUI / background run 等項目維持 deferred。
   - 只有在真實 dogfood 產生痛點時才開新批次。

## Verification Entry Points

快速分層檢查：

```bash
scripts/workflows/smoke-layer.sh contracts
scripts/workflows/smoke-layer.sh orchestration
```

完整 release gate：

```bash
scripts/workflows/smoke-per-stage.sh
```
