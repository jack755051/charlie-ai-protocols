# Strategy: Shared Language & ADR Discipline (共同語彙與決策紀錄紀律)

> 改寫自外部 `engineering/grill-with-docs` skill；CAP 內當作 **methodology strategy**。要解決的問題：跨 agent 與跨會期的語彙漂移、決策原因散落於對話歷史、後人重新爭辯已 settled 的選型。

## 1. 適用情境 (When To Use)
- 接到使用者需求時，先用此 strategy 對齊「你說的 X 是不是我以為的 X」。
- 跨 Bounded Context 的 spec 撰寫、跨模組重構、不同 agent 對同一概念有不同稱呼。
- 做出「難以反悔」的選型（例如 SQL vs NoSQL、認證機制、跨服務通訊風格）。

不適用：trivial wording（comment 拼字、log 文案）、明顯一次性的命名。**過度開 ADR 是雜訊，不是治理。**

## 2. 兩個 SSOT
- **`CONTEXT.md` / domain glossary**：本 repo 對 domain 詞彙的單一定義。所有 agent 講話必須對齊這份。若不存在，**lazily** 在第一次需要對齊詞彙時建立。
- **`docs/adr/` (或專案約定路徑)**：架構決策紀錄。每份 ADR 描述一個有實質取捨的選擇與理由。
- 多 context repo 用 `CONTEXT-MAP.md` 在 root 指出每個 context 的 `CONTEXT.md` 與 `docs/adr/` 路徑。

## 3. 對話中的紀律 (Live Discipline)

### 3.1 用既有 glossary 挑戰
使用者用的詞 vs `CONTEXT.md` 的定義不一致 → **立即 call out**。
> 「你的 glossary 把 `cancellation` 定義為 X，但你剛剛似乎在指 Y — 是哪一個？」

### 3.2 Sharpen fuzzy / overloaded 詞
模糊詞 → 提一個精準 canonical 替代。
> 「你說 `account` — 你是指 Customer 還是 User？這兩個是不同東西。」

### 3.3 用具體 scenario 壓力測試 domain 關係
討論 domain 關係時用具體 case 逼出邊界。發明 edge case 讓使用者必須對概念邊界精準。

### 3.4 跟代碼 cross-reference
使用者陳述 X 怎麼運作 → 對代碼。發現矛盾立刻 surface：
> 「你說可以部分取消，但代碼只取消整單 — 哪個是真的？」

### 3.5 Inline 更新 `CONTEXT.md`
詞彙當下確認當下寫，**不要 batch**。
- 命名一個 deepened module 用了 `CONTEXT.md` 還沒收的概念 → 當場補進去。
- 模糊詞當場 sharpened → 當場改 `CONTEXT.md`。
- 別讓 `CONTEXT.md` 黏實作細節；只放 domain expert 也覺得有意義的詞。

## 4. ADR 開不開的三條鐵律 (All Three Required)
**只有以下三條 **同時成立** 才開 ADR：**
1. **Hard to reverse** — 後悔成本實質高（資料 schema、認證機制、服務拆分線、跨團隊合約）。
2. **Surprising without context** — 未來 reader 會疑「為什麼這樣做？」（沒寫下來就會被人重提案）。
3. **Real trade-off** — 真的有替代方案，是有理由地選了某個。

少一條就跳過。短期決定（"目前沒空 / 反正之後會改"）、自證明顯（"用 HTTPS 而不是 HTTP"）→ 不要 ADR。

## 5. ADR 與 CONTEXT 格式 (Minimum Shape)

### CONTEXT.md 格式（CONTEXT-FORMAT 精神）
```markdown
# {Context name}

簡短一段 domain 概述（一兩句）。

## Glossary

- **Term A** — 一句話定義 + 必要時的 1-2 句澄清。誰是 actor、什麼狀態下會被觸發、跟誰有對應關係。
- **Term B** — 同上格式。
- **不要寫**：實作細節、code snippet、檔案路徑、UI wording。
```

### ADR 格式（ADR-FORMAT 精神）
```markdown
# ADR-XXXX: {語意化標題，不是流水號}

## Status
{Proposed | Accepted | Superseded by ADR-YYYY | Deprecated}

## Context
真正的 trade-off 是什麼？為什麼這個決策是 hard to reverse？哪些因素逼我們選一邊？

## Decision
我們選了什麼。**用 imperative 語氣**：「採用 X」、「禁止 Y」。

## Consequences
正面、負面、需要持續注意的。誰會受影響、需要什麼配套。

## Alternatives considered
真實考慮過的其他選項，每個一句說為什麼沒選。
```

## 6. 與其他 strategy 的關係
- 與 **`tdd-vertical-slice.md`**：Test 名稱與 interface 用 glossary 詞彙。
- 與 **`architecture-deepening.md`**：deepening 候選命名要對齊 glossary；user 拒絕 candidate 且理由 hard-to-reverse → 提議 ADR。
- 與 **`vertical-slice-planning.md`**：PRD / TechPlan 用 glossary 詞彙；跨 slice 共用概念進 glossary。

## 7. 與 CAP agent 的對應
- **01-Supervisor**：跨 agent 整合時最常需要對齊語彙；catch agent 之間的詞彙漂移。
- **02-TechLead**：TechPlan 用 glossary 詞彙；架構選型決策若符合三條鐵律 → 開 ADR。
- **90-Watcher**：稽核 spec / 代碼是否漂離 `CONTEXT.md` 詞彙；ADR 缺漏時 flag。

## 8. 邊界與禁令 (Boundaries)
- 不要把 trivial 命名 escalate 成 glossary 條目。
- 不要為「沒空 / 之後改」開 ADR。那不是 trade-off 是延後。
- 不要把 `CONTEXT.md` 寫成 implementation diary。
- 不要 batch glossary 更新到 PR 結尾 — 對話當下做。

## 9. 驗收 (Success Criteria)
- 任務結束時，新出現的 domain 詞已進 `CONTEXT.md`，或明確標記為「不該進去」的 implementation 細節。
- 三條鐵律 ADR 在符合條件處有開（且只開一次）；不符合條件的決策沒被 ADR 噪音化。
- 後續 agent 讀同一份 spec / 代碼時，名詞語意不會分歧。
