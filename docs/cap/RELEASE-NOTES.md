# CAP Release Notes

> 本檔只記 **CAP lean 重構（2026-05-15 起）以後**的 release 摘要。
> Lean 重構之前的完整 release narrative（v0.19 → v0.24.11，含 P0–P10
> phase 治理、Karpathy Phase 1–2 dogfood、Phase 5 observability 等）已搬到：
>
> [`development-records/archive/release-notes/cap-release-notes-pre-lean.md`](../../development-records/archive/release-notes/cap-release-notes-pre-lean.md)
>
> 需要查歷史 release 與當時的設計脈絡時去看 archive；日常開發只看本檔。

## Active anchors

- 定位 SSOT：[`CAP-POSITIONING.md`](CAP-POSITIONING.md)
- 重構任務清單：[`CAP-LEAN-ROADMAP.md`](CAP-LEAN-ROADMAP.md)
- 平台目標：[`PLATFORM-GOAL.md`](PLATFORM-GOAL.md)

## Lean restructuring cycle (2026-05-15)

一輪 docs / runtime / surface 收斂。整體淨減 ~13,000 行（含
component-fast runtime 與 provider-parity gate 兩塊大移除）。

| Commit | Slice |
|---|---|
| `5ebf3f0` | `chore(component-fast): remove frozen runtime profile` — 退 component-fast runtime（schemas / templates / scripts / capabilities / tests），保留歷史 evidence |
| `a1b4851` | `docs(workflows): classify AI-heavy workflows as legacy` — `project-spec-pipeline` / `project-implementation-pipeline` / `project-qa-pipeline` / `supervisor-orchestration` 4 個 YAML 頂端加 legacy status header |
| `5cb3cb6` | `docs(skills): classify agent skills by CAP usage tier` — agent-skills/README 重寫為 governance / advisory / deferred 三層 tier，廢止「agent army」敘事 |
| `3ed5f64` | `chore(dogfood): remove provider parity runtime surface` — 退 `provider-parity-check.sh` / `PROVIDER-PARITY-E2E.md` / 對應 test + smoke wiring；保留 development-records 歷史 |
| `4817706` | `docs(cap): audit deferred expansion surfaces` — 對 promote / design source / Karpathy / replay / detached / marketplace 6 個 surface 做 keep / defer / remove 裁定 |
| `329441f` | `docs(cap): drop marketplace publish aspiration from active docs` — ARCHITECTURE.md "draft / 下一階段" 拿掉 marketplace bullet |
| `ce2576d` | `chore(workflow): remove detached run stub` — 移除 `cap workflow run -d` / `run-task -d` 未實作 stub（4 處 flag-parse + 2 處 no-op block + 2 處 usage 字串）|
| `f9f71c6` | `docs(cap): checkpoint lean convergence status` — 8 commit 一輪後 pause-and-read snapshot |
| `040f33a` | `docs(cap): add lean roadmap and surface in indexes` — 引入 [`CAP-LEAN-ROADMAP.md`](CAP-LEAN-ROADMAP.md) 作為收斂任務清單 SSOT |
| `a9baecb` | `docs(cap): prune active docs surface` — docs/cap/ 從 34 → 12 active core docs；22 份歷史 / 設計 memo 搬到 `development-records/archive/docs-cap/` |
| `f753538` | `docs(cap): repair links after docs surface prune` — README / TODOLIST / ARCHITECTURE / 4 個 policies 內殘留 stale path 修補 |

## Provider readiness（同一週稍前）

| Commit | Slice |
|---|---|
| `738d1ae` | `docs(decision): define provider readiness boundary` — ADR-3 立邊界（CAP 不擁有 provider login；CAP 擁有 readiness；AI workflow fail-fast）|
| `4ff7d9a` | `docs(cap): track provider readiness implementation tasks` — `PROVIDER-READINESS-TASKS.md` P0–P4 任務清單入版控 |
| `4dc7af8` | `feat(provider): define provider readiness schema` — `schemas/provider-readiness.schema.yaml` v1 + test 14 cases / 29 assertions |
| `21312a1` | `feat(provider): report auth readiness in provider doctor` — `cap provider doctor --json` 對齊 schema；11 cases / 33 assertions |
| `6061e0b` | `feat(provider): preflight AI workflows before provider execution` — workflow 進入 AI step 前 fail-fast；19 cases / 60 assertions |

P0 + P1 + P2 全綠後，ADR-1 Q6 規定的第二次 one-shot evidence run 的
precondition 已滿足；retry 仍是 operator decision。

## ADRs landed this cycle

- [`development-records/decisions/component-fast-core-vs-profile-2026-05-15.md`](../../development-records/decisions/component-fast-core-vs-profile-2026-05-15.md)
- [`development-records/decisions/cap-input-boundary-prompt-vs-structured-2026-05-15.md`](../../development-records/decisions/cap-input-boundary-prompt-vs-structured-2026-05-15.md)
- [`development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md`](../../development-records/decisions/cap-provider-readiness-boundary-2026-05-15.md)

## Status after this cycle

- `docs/cap/` = **12 active core docs**
- 22 historical / deferred / design memos archived to
  `development-records/archive/docs-cap/`
- v0.19 → v0.24.11 release narrative archived to
  `development-records/archive/release-notes/cap-release-notes-pre-lean.md`
- Remaining audit-derived removal slices (operator-pending):
  - `chore(skills): remove karpathy workflows + capabilities`
  - `chore(workflows): remove design source runtime`

## Convention

新增條目時：

- 一行一條，commit hash + slice subject + 一行說明（取 commit body 第一段）。
- 不重寫歷史敘事；舊 release narrative 一律去 archive 看。
- 重大決策另開 ADR 至 `development-records/decisions/`，本檔僅引用。
