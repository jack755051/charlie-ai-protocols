# CAP H1 Closeout — Replay Contract

> **狀態**：H1 #1–#5 全段於 main 落地（commits `3957fad` / `bfcd054` / `5c54b39` / `0d7d94f` + 本 closeout commit），已 push origin/main。Smoke 78/78 passed。
>
> H1 是把 A0 #4 寫進 envelope 的 baseline 變成「可驗證」的契約：給定一個歷史 `run_id`，回答「是否還能 replay」。本文件做平台收斂：問題、五個子項、SSOT、deferred items 三件事。

## 1. H1 解決的問題

A0 #4 之後每次 run 在 `agent-sessions.json` envelope 都記錄了 `agent_skills_baseline`（cap_version + git_commit + dir_hash + per-file hashes），但**沒有任何 consumer 知道怎麼用**：
- 沒有判斷邏輯（baseline 漂移到什麼程度才算 drift？）
- 沒有 verdict contract（drift 後該怎麼分級？）
- 沒有 CLI 入口（使用者要怎麼問 replay readiness？）
- 沒有獨立 snapshot 檔（外部工具想看 baseline 必須 parse 整個 sessions ledger）

H1 把這四個 gap 填上。每次 run 完，可以跑 `cap replay verify <run_id>` 拿到 5-state verdict（replayable / drifted_compatible / drifted_incompatible / unverifiable / not_found），envelope 結構穩定可被 promote / archive / CI 消費。

## 2. 五個子項與 commit chain

| Sub-item | 範圍 | Commit | 主要產物 |
|---|---|---|---|
| **H1 #1** | design memo（doc-only baseline） | `3957fad` | `docs/cap/REPLAY-CONTRACT-DESIGN.md` |
| **H1 #2** | replay-verdict schema + fixture-based jsonschema test | `bfcd054` | `schemas/replay-verdict.schema.yaml`、`tests/scripts/test-replay-verdict-schema.sh`（12 cases） |
| **H1 #3** | verifier engine module + Python-side test | `5c54b39` | `engine/replay_verifier.py`、`tests/scripts/test-replay-verifier.sh`（25 assertions） |
| **H1 #4** | `cap replay verify` CLI + per-run snapshot mirror + cap-entry registration + e2e | `0d7d94f` | `scripts/cap-replay.sh`、`scripts/cap-entry.sh` 加 `[Replay]` 區塊、`tests/e2e/test-cap-replay-verify.sh`（18 assertions） |
| **H1 #5** | policy SSOT + user guide + closeout + TODOLIST | 本 commit | `policies/replay-contract.md`、`docs/cap/REPLAY-USER-GUIDE.md`、本 closeout、TODOLIST 章節 |

> 依使用者 commit-granularity 規則：每個子項獨立 commit，依 doc → schema → runtime → harness → docs/closeout 風險遞增順序。每個 sub-item 落地後 push，避免長期 unpushed 累積。

## 3. SSOT 索引

### 3.1 Policies

| 路徑 | 角色 |
|---|---|
| [`policies/replay-contract.md`](../../policies/replay-contract.md) | H1 normative SSOT：scope / verdict 語意 / drift 範圍 / CLI exit code / 持久化規則 / consumer 義務 / forward look |

### 3.2 Schemas

| 路徑 | 角色 |
|---|---|
| [`schemas/replay-verdict.schema.yaml`](../../schemas/replay-verdict.schema.yaml) | verdict envelope contract；7 top-level required + drift_details 7 子欄位 |

### 3.3 Engine

| 模組 | 角色 |
|---|---|
| [`engine/replay_verifier.py`](../../engine/replay_verifier.py) | `verify_run` 純函式 + `write_verdict` / `write_snapshot_mirror` idempotent 持久化 + argparse CLI |
| [`engine/agent_skills_snapshot.py`](../../engine/agent_skills_snapshot.py) | A0 #4 落地，被 H1 verifier 直接消費（compute_snapshot / compute_summary） |

### 3.4 Shell harness

| 路徑 | 角色 |
|---|---|
| [`scripts/cap-replay.sh`](../../scripts/cap-replay.sh) | shell wrapper；run_id resolution / --json / --no-write / 人類可讀摘要 / exit code 映射 |
| [`scripts/cap-entry.sh`](../../scripts/cap-entry.sh) | `replay` subcommand 註冊 + help 加 `[Replay]` 區塊 |

### 3.5 Tests

| 路徑 | 範圍 |
|---|---|
| [`tests/scripts/test-replay-verdict-schema.sh`](../../tests/scripts/test-replay-verdict-schema.sh) | schema gate（5 positive + 7 negative） |
| [`tests/scripts/test-replay-verifier.sh`](../../tests/scripts/test-replay-verifier.sh) | engine 純函式 + CLI（25 assertions / 9 cases） |
| [`tests/e2e/test-cap-replay-verify.sh`](../../tests/e2e/test-cap-replay-verify.sh) | shell wrapper e2e（18 assertions / 7 cases） |

> Smoke：`scripts/workflows/smoke-per-stage.sh` 從 A0 closeout 後的 75 step 升至 **78 step**（+3 H1 step），全綠 0 regression。

### 3.6 User-facing docs

| 路徑 | 角色 |
|---|---|
| [`docs/cap/REPLAY-CONTRACT-DESIGN.md`](REPLAY-CONTRACT-DESIGN.md) | H1 design memo（rationale / Q&A locked） |
| [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) | user guide（場景範例 / 進階用法 / FAQ） |

## 4. 設計裁定（locked，不再重議）

| 編號 | 內容 |
|---|---|
| Q1 | 5-state verdict enum（replayable / drifted_compatible / drifted_incompatible / unverifiable / not_found） |
| Q2 | per-run snapshot 走 `<run_dir>/snapshots/` subdir 結構（為 H2 / H3 預留 project-skills / workflows / capabilities / constitution snapshot） |
| Q3 | H1 v1 drift 範圍只判 builtin agent-skills；project skill drift 在 schema 預留 `drift_details.project_skill_diff = null` 作為 forward contract，H2 才填值 |
| Q4 | verdict 持久化到 `<run_dir>/replay-verdict.json`，覆寫舊檔（idempotent：相同 verdict 不重寫） |

附帶設計拍板：

- `cap_version` / `git_commit` mismatch 是 **soft signal**，不直接降 verdict（避免 release-tag 噪音）。
- `prompt_file` 路徑做 normalize：拿掉 `agent-skills/` 前綴後與 baseline `prompt_files` dict key 比對。
- snapshot 檔是 envelope 投影，envelope 是 SSOT；衝突時以 envelope 為準。
- `cap replay verify` 預設 `--write`；`--no-write` 為 read-only mode。

## 5. 沒解決的部分（Deferred to H2 / H3 / H4+）

| 項目 | Defer 給 |
|---|---|
| Project layer skill drift（`<project_root>/.cap/skills.yaml` 變動） | H2 |
| Workflow YAML drift（該 run 用過的 workflow 檔被改） | H2 |
| `--strict-unverifiable` 旗標（把 unverifiable 升為 exit 4） | H2 |
| `snapshots/project-skills.yaml.json` / `snapshots/workflows/<id>.yaml.json` mirror | H2 |
| Capability schema drift（`schemas/capabilities.yaml` 變動） | H3 |
| Constitution drift（`<project_root>/.cap/constitution.yaml` allowed_capabilities 變動） | H3 |
| `snapshots/capabilities.yaml.json` / `snapshots/constitution.yaml.json` | H3 |
| Full replay execution（真重跑、pinned baseline 模式） | H4+ |
| `cap replay diff <run_id>` 顯示 file-level diff | 後續 |
| `cap replay status` 列出所有 run 的 verdict | 後續 |
| Cross-run verdict aggregation | 後續 |

## 6. 影響半徑（Backward Compatibility）

- **A0 #4 之前的 run**：envelope 沒 `agent_skills_baseline` → verdict 永遠是 `unverifiable`。
- **不跑 `cap replay verify`** → behaviour 不變，不會自動產生新檔。
- **Schema 升版**：v1；breaking change 才 bump。
- **Smoke**：72 baseline (v0.22.0 GA) → 75 (A0) → 78 (H1)，全綠 0 regression。

## 7. Test Verification

```bash
# Full smoke
bash scripts/workflows/smoke-per-stage.sh
# 預期：Summary: 78 passed, 0 failed, 0 skipped

# H1 個別 fixtures
bash tests/scripts/test-replay-verdict-schema.sh    # H1 #2: 12 assertions
bash tests/scripts/test-replay-verifier.sh          # H1 #3: 25 assertions
bash tests/e2e/test-cap-replay-verify.sh            # H1 #4: 18 assertions
```

## 8. 後續閱讀順序建議

如果你是第一次看 H1：

1. 先讀 [`docs/cap/REPLAY-USER-GUIDE.md`](REPLAY-USER-GUIDE.md) — 5 分鐘掌握「怎麼用」。
2. 再讀 [`policies/replay-contract.md`](../../policies/replay-contract.md) — 深入規則 / verdict 語意 / consumer 義務。
3. 對 design rationale 有興趣 → [`docs/cap/REPLAY-CONTRACT-DESIGN.md`](REPLAY-CONTRACT-DESIGN.md)。
4. 對下一步（H2 project skill drift）有興趣 → 等 H2 design memo。
