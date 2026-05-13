# CAP A0 Closeout — Agent-Skills Baseline Policy

> **狀態**：A0 #1–#5 全段於 main 分支落地（commits `6ec0c26` / `f590d95` / `4d52bae`，已 push origin/main）。本文件是 platform-level 收斂：回答「A0 解決了什麼問題」、「五個子項在 SSOT 樹上落在哪裡」、「A0 沒解決的部分由誰接手」三件事。
>
> A0 不是新功能 milestone，是把「使用者怎麼安全地客製化 builtin agent-skills」這條長期模糊的路徑收斂為三層 (project / shared / builtin) 治理契約：read-only baseline + 可審計 override + 可重現 baseline snapshot。後續 H1 Replay Contract 會以 A0 #4 的 baseline snapshot 為起點。

## 1. A0 解決的三個問題

| 問題 | A0 之前狀態 | A0 之後狀態 |
|---|---|---|
| **使用者怎麼自訂 builtin agent-skill？** | 沒有正式說法。`00-core-protocol.md` §3 只說 `agent-skills/` 唯讀，沒給替代路徑；P9 #3 已實作三層 resolver，但沒文件指引使用者怎麼用。 | `policies/agent-skills-baseline.md` 為 SSOT；`docs/cap/AGENT-SKILLS-CUSTOMIZATION.md` 是 user-facing quickstart；三層 resolver 的 override / disable / replace 三模式有 schema 欄位 + 範例 + 衝突處理規則。 |
| **使用者怎麼**禁用**或**取代**某個官方 skill？** | 沒有 mask 語意。`enabled: false` 只在同一份 registry 內生效；高層 layer 寫 `enabled: false` 不會遮蔽低層同 `skill_id`，反而被當成「未啟用的合法 entry」處理。 | `disabled: true` tombstone mask（不可選中、不可 fallback、binding report 仍可見）+ `replaces: <skill_id>` 替代（target 自動 mask + 可選 capability 繼承）。Multi-replace 同一 target → halt with `OverrideContractError`。 |
| **怎麼判斷一個舊 run 用的 builtin baseline 與現在的 baseline 是否一致？** | 沒有錨點。`agent-sessions.json` 只記 session-level 資訊；replay / diff 拿不到「當時的 builtin 是什麼版本 / 有哪些 prompt 被改了」。 | 每次 run 在 `agent-sessions.json` envelope 寫 `agent_skills_baseline`（cap_version / git_commit / git_dirty / dir_hash / per-file hashes / baseline_root / computed_at）；`workflow-result.json` 帶 compact projection；獨立 per-run snapshot 檔 deferred 給 H1。 |

## 2. 五個子項與 commit chain

| Sub-item | 內容 | Commit | 主要產物 |
|---|---|---|---|
| **A0 #1** | 官方 agent-skill baseline policy SSOT | `6ec0c26` | `policies/agent-skills-baseline.md`（新） |
| **A0 #2** | runtime override 契約（`disabled` + `replaces`） | `f590d95` | `schemas/skill-registry.schema.yaml` 兩 field + `engine/runtime_binder.py:_apply_override_contract` + `OverrideContractError` |
| **A0 #3** | binding provenance audit checklist | `6ec0c26` | `docs/cap/P9-SOURCE-RESOLVER-DESIGN.md` §11（review，不新增 producer） |
| **A0 #4** | baseline checksum / version snapshot | `4d52bae` | `engine/agent_skills_snapshot.py`（新）+ `cap-workflow-exec.sh` 鉤點 + envelope projection schema |
| **A0 #5** | docs / migration note for users | `6ec0c26` | `docs/cap/AGENT-SKILLS-CUSTOMIZATION.md`（新） |

> A0 #1 / #3 / #5 三者本質都是 doc-only，依使用者的 commit-granularity 指示（"先做 #1/#3/#5 doc-only，再做 #2 runtime contract，最後做 #4 baseline checksum"）共同收斂為一個 doc-only commit；#2 與 #4 各自獨立 commit，避免 runtime 行為與 schema / producer / harness 改動互相牽連。

## 3. SSOT 索引

### 3.1 Policies（治理規範）

| 路徑 | 角色 |
|---|---|
| [`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md) | A0 normative SSOT：write authority、自訂路徑、override 契約、hard constraints |
| [`policies/agent-registry.md`](../../policies/agent-registry.md) | legacy `.cap.agents.json` registry policy（v1.2，A0 加 cross-ref） |

### 3.2 Schemas（machine-readable contracts）

| 路徑 | A0 觸及範圍 |
|---|---|
| [`schemas/skill-registry.schema.yaml`](../../schemas/skill-registry.schema.yaml) | 新增 `disabled` / `replaces` per-skill fields |
| [`schemas/agent-session.schema.yaml`](../../schemas/agent-session.schema.yaml) | 加 envelope-level comment 描述 `agent_skills_baseline` 欄位 |
| [`schemas/workflow-result.schema.yaml`](../../schemas/workflow-result.schema.yaml) | 新增 optional `agent_skills_baseline` projection |

### 3.3 Engine（producers / runtime hooks）

| 模組 | 角色 |
|---|---|
| [`engine/runtime_binder.py`](../../engine/runtime_binder.py) | `_apply_override_contract` + `_collect_masked_hint` + `_find_candidates / _find_fallback` mask filter；`OverrideContractError` exception |
| [`engine/agent_skills_snapshot.py`](../../engine/agent_skills_snapshot.py) | `compute_snapshot` / `compute_summary` / `attach_to_envelope` + argparse CLI（`snapshot` / `summary` / `attach`） |

### 3.4 Shell harness

| 路徑 | A0 觸及範圍 |
|---|---|
| [`scripts/cap-workflow-exec.sh`](../../scripts/cap-workflow-exec.sh) | run-start 鉤 `agent_skills_snapshot.py attach` 把 baseline 寫入新 ledger（best-effort，失敗只 warn 不 halt） |

### 3.5 Tests

| 路徑 | Cases |
|---|---|
| [`tests/scripts/test-skill-registry-resolver.sh`](../../tests/scripts/test-skill-registry-resolver.sh) | P9 #3 baseline，A0 一併補 wire 進 smoke（22 cases） |
| [`tests/scripts/test-skill-registry-override.sh`](../../tests/scripts/test-skill-registry-override.sh) | A0 #2 override 契約（7 cases / 29 assertions） |
| [`tests/scripts/test-agent-skills-snapshot.sh`](../../tests/scripts/test-agent-skills-snapshot.sh) | A0 #4 baseline snapshot（7 cases / 16 assertions） |

> Smoke 全綠：`scripts/workflows/smoke-per-stage.sh` 從 v0.22.0 GA 的 72 step 升至 75 step（+3 個 A0 step），0 failed / 0 skipped。

### 3.6 Cross-reference docs

| 路徑 | 增補 |
|---|---|
| [`agent-skills/00-core-protocol.md`](../../agent-skills/00-core-protocol.md) | §3 唯讀規則加 cross-ref，指向 baseline policy 與 customization guide |
| [`docs/cap/P9-SOURCE-RESOLVER-DESIGN.md`](../../docs/cap/P9-SOURCE-RESOLVER-DESIGN.md) | 新增 §11 Binding Provenance Audit Checklist（A0 #3 收斂） |

## 4. 沒解決的部分（Deferred to H1+）

| 項目 | 為什麼 deferred | 可能接手者 |
|---|---|---|
| 獨立 per-run baseline snapshot 檔（`~/.cap/projects/<id>/runs/<run_id>/agent-skills-snapshot.json`） | A0 #4 走 envelope-only 路徑：snapshot 寫在 `agent-sessions.json` envelope 的 top-level 欄位。獨立檔對 replay UX 更友善但會多一條同步路徑。 | **H1 Replay Contract**（如有需要） |
| Baseline drift 偵測 / replay readiness verdict | A0 #4 只記錄 baseline；不判斷「現在 baseline 跟舊 run baseline 是否一致」。verdict 邏輯（hash 比對 + project layer mask 比對 + 不一致時的 actionable hint）屬於下一個契約層。 | **H1 Replay Contract** |
| `cap replay` CLI surface | 沒有 CLI 入口供使用者 query "我這個舊 run 還能 replay 嗎？" | **H1 Replay Contract** |
| `result.md` 人類可讀 baseline 摘要 | `workflow-result.json` 已有 projection schema 欄位，但 `engine/result_report_builder.py` 還沒寫成 `result.md` 渲染區塊。 | P7 result builder 後續維護 |
| Marketplace / shared registry 安裝流程 | A0 已支援 shared layer 路徑，但沒有「下載 / 升級 shared skill」的 CLI 流程。 | Phase 11 promote / publish |
| `replaces` target 不存在的 marketplace 自動安裝 | 目前是 warn-but-accept，沒有自動拉取目標 skill 的機制。 | Phase 11 promote / publish |

## 5. 影響半徑（Backward Compatibility）

- **Pre-A0 registry 不寫 `disabled` / `replaces` 一切照舊**：兩個欄位是 additive，舊 `<project_root>/.cap/skills.yaml` 不需修改。
- **Pre-A0 run（沒有 `agent_skills_baseline`）仍可讀**：`workflow-result.schema.yaml` 將欄位定為 nullable；replay 工具須把 null 視為「unknown baseline」。
- **舊 cap-workflow-exec.sh 寫的 envelope** 缺 `agent_skills_baseline`。下一次 attach（如 H1 Replay 在 inspection 時補寫）能補；但 attach 是 idempotent，不會覆蓋已寫入的 baseline。
- **smoke-per-stage 既有 72 step 0 regression**；新加 3 step 全綠。

## 6. Test Verification

```bash
# A0 全段 smoke verification（部分摘要）
bash scripts/workflows/smoke-per-stage.sh
# 預期：Summary: 75 passed, 0 failed, 0 skipped

# 個別 A0 fixtures
bash tests/scripts/test-skill-registry-override.sh        # A0 #2: 29 assertions
bash tests/scripts/test-agent-skills-snapshot.sh          # A0 #4: 16 assertions
```

## 7. 後續閱讀順序建議

如果你是第一次看 A0 系列：

1. 先讀 [`policies/agent-skills-baseline.md`](../../policies/agent-skills-baseline.md)（policy SSOT）— 5 分鐘掌握規則。
2. 再讀 [`docs/cap/AGENT-SKILLS-CUSTOMIZATION.md`](../../docs/cap/AGENT-SKILLS-CUSTOMIZATION.md)（user guide）— 看四個情境範例。
3. 對 binding 行為有興趣 → 讀 [`docs/cap/P9-SOURCE-RESOLVER-DESIGN.md`](../../docs/cap/P9-SOURCE-RESOLVER-DESIGN.md) §11 audit checklist。
4. 對 baseline replay 有興趣 → 等 H1 Replay Contract 落地（本文件 §4 deferred 列表）。
