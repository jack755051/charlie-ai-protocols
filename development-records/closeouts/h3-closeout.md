# CAP H3 Closeout — Drift Expansion (Cost-Aware Minimal)

> **狀態**：H3 #1b–#5 全段於 main 落地（commits `66d55fd` / `cf7a853` / `55ed7ae` / `15374fe` + 本 closeout commit），已 push origin/main。Smoke 81/81 passed。
>
> H3 把 `cap replay verify` 從 H1+H2 雙軸擴成 5 軸：新增 workflow YAML、constitution、capability schema 三軸 whole-file hash drift。Per Cost-Aware lock-down：每軸只做 SHA-256，不做 selection 精度，最多到 `drifted_compatible`。

## 1. H3 解決的問題

H1 + H2 之後，verdict 看不到下面三件事的變動：
- 使用者改了該 run 用過的 workflow YAML（step 順序、capability 換、新增 / 拿掉 step）
- `<project_root>/.cap/constitution.yaml` 變了（allowed_capabilities / workflow_policy / binding_policy）
- `<cap_root>/schemas/capabilities.yaml` 變了（default_agent / allowed_agents）

H3 minimal 把這三個 input axis 補上，**但只做 whole-file hash**。哲學上對齊 A0 #4 "input baseline → drift detection" 模式：每個影響 binding/execution 結果的 input artifact 都有 snapshot，但精度限制在 file-level，避免 H3 範圍爆炸。

## 2. 五個子項與 commit chain

| Sub-item | 範圍 | Commit | 主要產物 |
|---|---|---|---|
| **H3 #1b** | design memo lock to minimal scope | `66d55fd` | `docs/cap/H3-DRIFT-EXPANSION-DESIGN.md`（rewrite from DRAFT） |
| **H3 #2** | 3 個 input snapshot 模組 | `cf7a853` | `engine/{workflow_yaml,constitution,capability_schema}_snapshot.py` + 21-assertion test |
| **H3 #3** | schema widening + verifier 5-axis aggregation | `55ed7ae` | `replay-verdict.schema.yaml` + 5 schema fixture cases + 13 multi-axis test cases |
| **H3 #4** | runtime hooks + cap-replay output + e2e | `15374fe` | `cap-workflow-exec.sh` 3 attach hooks + `cap-replay.sh` 5-axis output + 11-assertion e2e |
| **H3 #5** | docs / closeout | 本 commit | `policies/replay-contract.md` v1.2、`docs/cap/REPLAY-USER-GUIDE.md` §9、本 closeout、TODOLIST 章節 |

## 3. SSOT 索引

### 3.1 Policies

| 路徑 | 角色 |
|---|---|
| [`policies/replay-contract.md`](../../policies/replay-contract.md) | v1.2 normative SSOT — 5 軸 drift detection + whole-file hash 精度限制 + 6 個 mirror 檔規則 |

### 3.2 Schemas

| 路徑 | 角色 |
|---|---|
| [`schemas/replay-verdict.schema.yaml`](../../schemas/replay-verdict.schema.yaml) | `drift_details` 加 `workflow_yaml_diff` / `constitution_diff` / `capability_schema_diff` 三 nullable object 欄位；`schema_version: 1` 不變 |

### 3.3 Engine modules

| 模組 | 角色 |
|---|---|
| [`engine/workflow_yaml_snapshot.py`](../../engine/workflow_yaml_snapshot.py) | 工作流 YAML whole-file hash + CLI |
| [`engine/constitution_snapshot.py`](../../engine/constitution_snapshot.py) | constitution.yaml whole-file hash + CLI |
| [`engine/capability_schema_snapshot.py`](../../engine/capability_schema_snapshot.py) | capabilities.yaml whole-file hash + CLI |
| [`engine/replay_verifier.py`](../../engine/replay_verifier.py) | `_compute_workflow_yaml_axis` / `_compute_constitution_axis` / `_compute_capability_schema_axis`；`_aggregate_axes` 改 variadic 支援 5 軸；3 個新 mirror writers |

### 3.4 Shell harness

| 路徑 | 變更 |
|---|---|
| [`scripts/cap-workflow-exec.sh`](../../scripts/cap-workflow-exec.sh) | run-start 多 3 個 best-effort attach（workflow YAML / constitution / capability schema）；對齊 A0 #4 / H2 #4 失敗 warn-only 模式 |
| [`scripts/cap-replay.sh`](../../scripts/cap-replay.sh) | per-axis output 從 2 軸擴到 5 軸；mirror 檔 listing 從 3 個擴到 6 個；H3 #4 順手修：local 變數 `CAP_ROOT`→`SCRIPT_REPO`，避免 wrapper 覆蓋 env CAP_ROOT |

### 3.5 Tests

| 路徑 | 範圍 |
|---|---|
| [`tests/scripts/test-h3-input-snapshots.sh`](../../tests/scripts/test-h3-input-snapshots.sh) | 3 個 snapshot 模組 combined（12 cases / 21 assertions） |
| [`tests/scripts/test-replay-verdict-schema.sh`](../../tests/scripts/test-replay-verdict-schema.sh) | schema fixture（H1+H2 既有 18 + H3 新 5 = 23 cases） |
| [`tests/scripts/test-replay-verifier-dual-axis.sh`](../../tests/scripts/test-replay-verifier-dual-axis.sh) | verifier multi-axis（H2 既有 17 + H3 新 13 = 30 assertions） |
| [`tests/e2e/test-cap-replay-verify.sh`](../../tests/e2e/test-cap-replay-verify.sh) | shell wrapper e2e（H1+H2.5 既有 24 + H3 新 11 = 35 assertions） |

> Smoke：`scripts/workflows/smoke-per-stage.sh` 從 H2 closeout 後的 80 step 升至 **81 step**（+1 H3 step：input snapshots；其他 H3 改動進既有 fixture），全綠 0 regression。

### 3.6 User-facing docs

| 路徑 | 角色 |
|---|---|
| [`docs/cap/H3-DRIFT-EXPANSION-DESIGN.md`](../../docs/cap/H3-DRIFT-EXPANSION-DESIGN.md) | H3 design memo (ACCEPTED, Cost-Aware Minimal) |
| [`docs/cap/REPLAY-USER-GUIDE.md`](../../docs/cap/REPLAY-USER-GUIDE.md) §9 | 使用者導向 H3 章節：5 軸範例、whole-file hash 精度限制、6 個 mirror 檔列表 |

## 4. 設計裁定（locked, Q1–Q6 = A）

| 編號 | 內容 |
|---|---|
| Q1 | workflow YAML axis 只 hash 該 run 用過的單一 workflow 檔；不做 dependent / dir-wide |
| Q2 | capability schema 全檔 hash；**不**做 per-capability hash |
| Q3 | binding_summary 不擴欄位；保持 H2 既有 step_id / selected_skill_id / skill_source |
| Q4 | constitution 整檔 hash；不做 per-block 拆分 |
| Q5 | shared layer skill drift **deferred** 到 H4+；H3 不碰 `<cap_home>/shared/` |
| Q6 | `schema_version` 留 1，widening forward contract |

附帶設計拍板：

- **Whole-file hash 精度限制**：H3 三軸最多輸出 `drifted_compatible`，永遠不會 emit `drifted_incompatible`。Caller 看到後自己決定要不要更深 inspect。
- **`--strict-unverifiable` flag deferred**：H1 + H2 + H3 共同 deferred；H4+ 才考慮。
- **Verifier 不修改 envelope**：與 H1 / H2 一致；補 envelope 走獨立 CLI。
- **Bug fix in H3 #4**：`scripts/cap-replay.sh` 把 local `CAP_ROOT`→`SCRIPT_REPO`，避免 wrapper 覆蓋 env CAP_ROOT（影響 capability_schema_snapshot 的 sandbox 可測試性）。

## 5. 沒解決的部分（Deferred to H4+）

| 項目 | 為什麼 deferred |
|---|---|
| Per-step workflow hash（區分 used vs unused steps） | 需要 binding_summary 擴 step→step_id 對映 + 每 step canonical-JSON hash |
| Per-capability schema hash | 需要 binding_summary 加 capability 欄位 + per-capability hash |
| Per-block constitution hash（allowed_capabilities / workflow_policy / binding_policy 拆） | YAML 解析 + per-block diff 邏輯 |
| Shared layer skill drift（`<cap_home>/shared/`） | 需要新 snapshot 模組 + 對齊 P9 #4 source layer 設計 |
| `--strict-unverifiable` flag | 把 unverifiable 升 exit 4 — 沒人喊，留 H4+ |
| Real replay execution（真重跑） | H4+ 主要工作 |
| Effective merged spec snapshot | 重跑 `_apply_override_contract`，scope 大 |
| Workflow `needs` cross-workflow drift | 視未來是否引入 workflow include 機制 |

## 6. 影響半徑（Backward Compatibility）

- **A0 #4 之前的 run**：envelope 連 `agent_skills_baseline` 都沒 → top-level verdict = `unverifiable`，三 H3 axes 都 `null`（保留 H1 既有契約）。
- **H1 既有 run**：envelope 沒 H3 baselines → 三 H3 axes 全部 `unverifiable_axis` 中立，top-level verdict 不變。
- **H2 既有 run**：同上。
- **新 H3 run**：cap-workflow-exec.sh 補 attach 三 H3 baselines → 完整 5-axis 判斷。
- **Schema_version 留 1**：所有現有 verdict 檔仍 schema-valid。
- **Smoke**：78 (H1) → 80 (H2) → 81 (H3)，全綠 0 regression。

## 7. Test Verification

```bash
# Full smoke
bash scripts/workflows/smoke-per-stage.sh
# 預期：Summary: 81 passed, 0 failed, 0 skipped

# H3 個別 fixtures
bash tests/scripts/test-h3-input-snapshots.sh                # H3 #2: 21 assertions
bash tests/scripts/test-replay-verdict-schema.sh             # H3 #3: 23 cases (18 H1+H2 + 5 H3)
bash tests/scripts/test-replay-verifier-dual-axis.sh         # H3 #3: 30 assertions (17 H2 + 13 H3)
bash tests/e2e/test-cap-replay-verify.sh                     # H3 #4: 35 assertions (24 H1+H2.5 + 11 H3)
```

## 8. Cost Snapshot（vs H2 closeout）

H1+H2+H3 累計 attach overhead per workflow run-start：
- A0 #4 agent_skills snapshot：~85 ms
- H2 project_skills snapshot：~60 ms
- H2 binding_summary：~37 ms
- H3 workflow_yaml：~30 ms（單檔 SHA-256）
- H3 constitution：~30 ms
- H3 capability_schema：~30 ms

**Total ~270 ms**（vs H2 215 ms baseline；+55 ms 為 3 個新 attach），仍遠在 1 秒以下。

每 run mirror 檔：6 個小 JSON 檔，總 size ~24 KB（加 H1+H2 既有的 16 KB → 40 KB total per run）。1000 個 run 累計 ~40 MB，可忽略。

## 9. 後續閱讀順序建議

1. 先讀 [`docs/cap/REPLAY-USER-GUIDE.md`](../../docs/cap/REPLAY-USER-GUIDE.md) §9 — 5 分鐘掌握 5-axis 用法。
2. 再讀 [`policies/replay-contract.md`](../../policies/replay-contract.md) v1.2 — verdict 5 軸聚合 normative + whole-file hash 精度規則 + 6 mirror 檔。
3. 對 design rationale 有興趣 → [`docs/cap/H3-DRIFT-EXPANSION-DESIGN.md`](../../docs/cap/H3-DRIFT-EXPANSION-DESIGN.md)（Q1-Q6 locked、deferred 列表）。
4. 對下一步（H4+ per-axis 精度 / shared layer / real replay execution）有興趣 → 等 H4 design memo。
