# CAP Platform TODO

> 本檔只保留「下一步該做什麼」。Lean 重構（2026-05-15 起）後，
> docs/cap/ 只保留 active core docs；歷史 backlog / phase roadmap
> / dogfood profile 等已搬到 `development-records/archive/docs-cap/`。
> 本 TODO 不再複製這些歷史層；需要時直接讀 archive。

## SSOT

| 需求 | 來源 |
|---|---|
| 目前定位與 active 工作項 | [docs/cap/CAP-LEAN-ROADMAP.md](docs/cap/CAP-LEAN-ROADMAP.md) |
| 確認 CAP 是什麼 / 不是什麼 | [docs/cap/CAP-POSITIONING.md](docs/cap/CAP-POSITIONING.md) |
| Provider readiness 實作任務 | [docs/cap/PROVIDER-READINESS-TASKS.md](docs/cap/PROVIDER-READINESS-TASKS.md) |
| 文件入口 | [docs/cap/README.md](docs/cap/README.md) |
| Release tag 對應功能 | [docs/cap/RELEASE-NOTES.md](docs/cap/RELEASE-NOTES.md) |

## Current Focus

對齊 `docs/cap/CAP-LEAN-ROADMAP.md`：

- P1（provider readiness + preflight）— **已落地**（commits `4dc7af8` /
  `21312a1` / `6061e0b`）。
- P2（skill model reclassification）— **已落地**（commit `5cb3cb6`）。
- Audit-derived removal queue — slice #1 / #2 landed（marketplace docs
  + detached stub）；slice #3（Karpathy runtime）+ slice #4（design
  source runtime）仍 pending operator 授權。
- Lean docs prune — **已落地**（commit `a9baecb`，docs/cap 34 → 12）。

下一個 active 待決：
- 是否進入 audit slice #3（Karpathy runtime removal）？
- 是否做新一輪 dogfood，讓收斂後的形狀面對真實使用？

## Deferred (do not re-open without dogfood pain)

- H5 / H6 / H7 replay precision
- detached / background runtime
- publish / marketplace workflow
- TUI / dashboard
- Karpathy / design source runtime（pending audit slice 授權）

## Verification Entry Points

```bash
scripts/workflows/smoke-layer.sh contracts
scripts/workflows/smoke-layer.sh orchestration
scripts/workflows/smoke-per-stage.sh
```
