# Strategy: Disciplined Diagnosis Loop (診斷六段鐵律)

> 改寫自外部 `engineering/diagnose` skill；CAP 內當作 **methodology strategy**，不引入 plugin 或 slash-command runtime。當 troubleshoot / QA / 任何修 bug 的 agent 收到「診斷類」任務時必須掛載。

## 1. 適用情境 (When To Use)
- 使用者明確說「diagnose / debug / 為什麼會這樣」。
- 出現 bug 報告、效能退化、間歇性失敗、unreproducible production incident。
- 既有 test 沒抓到的真實 regression，或 fix 一直 cherry-pick 卻反覆出現的 case。

不適用：純功能新增、新 spec 撰寫、純重構。那些走 TDD vertical slice 或 architecture deepening。

## 2. 核心理念 (Core Discipline)
**Phase 1（feedback loop）才是這個 strategy 真正的能力。** 其他五段都只是消費 Phase 1 產出的 pass/fail 訊號。沒有快速、決定性、agent-runnable 的訊號，再多代碼凝視都是浪費時間。Phase 1 不通過，**禁止**進入後面任何階段。

## 3. 六段流程 (Six-Phase Loop)

### Phase 1 — Build a feedback loop (把 90% 力氣花在這裡)
- 嘗試順序（從便宜到昂貴）：
  1. Failing test（unit / integration / e2e — 看 bug 在哪個層）。
  2. curl / HTTP script 對 dev server。
  3. CLI invocation + fixture input + diff 對 known-good snapshot。
  4. Headless browser script (Playwright / Puppeteer) 驅動 UI。
  5. Replay captured trace（real network request payload / event log → disk → replay 進 isolated code path）。
  6. Throwaway harness（最小 subset of system，single function call exercise bug code path）。
  7. Property / fuzz loop（"sometimes wrong" → 1000 random inputs）。
  8. Bisection harness（state 之間用 `git bisect run`）。
  9. Differential loop（old vs new；diff outputs）。
  10. HITL bash script（最後手段，且必須結構化驅動人類點擊）。
- **Loop 是 product**：可以快多快、訊號可以多銳利、輸出可以多 deterministic（pin time、seed RNG、freeze network）。30 秒 flaky loop 幾乎沒用；2 秒 deterministic loop 是 superpower。
- **非 deterministic bug**：目標不是 clean repro 而是「higher reproduction rate」。Loop 100×、parallelise、stress、injection sleep 直到 50%+ 重現率才能 debug。
- **真的做不出 loop**：明示停止，列出嘗試清單，向使用者要 (a) 可重現環境、(b) captured artifact (HAR / log dump / core dump)、(c) 暫時 production instrumentation 授權。**不得**沒 loop 就跳到 Phase 2 後段亂猜。

### Phase 2 — Reproduce
- 跑 loop，看 bug 發生。
- 確認三件事：bug 發生的是 **使用者描述的 failure mode**（不是路過剛好的另一個錯）、跨多次 run 都重現（或非 deterministic 的高重現率）、symptom 已被精準捕捉（error message / wrong output / 慢時間）。
- 不重現 → 不准進 Phase 3。

### Phase 3 — Hypothesise (3–5 排序假說 + falsifiable)
- 一次產出 **3–5 個排序假說**，避免錨定第一個合理的想法。
- 每個假說必須 falsifiable：寫成 `If <X> is the cause, then <change Y> will make it disappear / <change Z> will make it worse`。寫不出 prediction 就不是假說，是 vibe，丟掉或 sharpen。
- 把 ranked list 給使用者看一眼再測。使用者常知道 #3 剛部署過，或哪些已經排除。Cheap checkpoint，但別 block — 使用者 AFK 就照排序自己跑。

### Phase 4 — Instrument
- 每個 probe 必須對應 Phase 3 的某一條 prediction。一次只動一個變數。
- 工具偏好：(1) Debugger / REPL inspection > (2) targeted log at distinguishing boundary > (3) **絕對不要** "log everything and grep"。
- **每條 debug log 帶唯一 prefix**，例如 `[DEBUG-a4f2]`。Phase 6 cleanup 一個 grep 就清乾淨；untagged log 會殘留下去污染未來。
- **效能 bug 走 perf branch**：log 通常騙人。先 baseline measurement (timing harness / `performance.now()` / profiler / query plan) → bisect。先量再改。

### Phase 5 — Fix + regression test (順序很重要)
- **regression test 在 fix 之前寫** — 但只有當存在 **correct seam** 才寫。
- Correct seam 定義：test 觸發的是 bug 真實發生時的 call site 模式。如果可用 seam 太淺（單 caller test 但 bug 需多 caller 鏈、unit test 重現不了 chain），test 給的是 false confidence。
- **沒 correct seam = finding 本身**。註記這件事。代碼架構正在阻止 bug 被鎖死，flag 給下一段（架構 deepening）。
- 有 correct seam：minimised repro → 寫 failing test → 看 fail → apply fix → 看 pass → 跑 Phase 1 loop 對 un-minimised scenario。

### Phase 6 — Cleanup + post-mortem (declared done 前必做)
- [ ] 原 repro 不再重現（再跑一次 Phase 1 loop）
- [ ] Regression test pass（或「沒 seam」事實已記錄）
- [ ] 所有 `[DEBUG-...]` instrumentation 已 grep 移除
- [ ] Throwaway prototype 刪除（或搬到明確標 debug 的位置）
- [ ] 哪條假說最後對了，寫進 commit / PR message — 讓下一個 debugger 學到
- **問自己**：什麼會阻止這個 bug 發生？答案如果牽涉架構（沒 test seam / tangled callers / hidden coupling），fix 落地後再 hand off 給 architecture deepening strategy。**fix 之前**不要做架構建議 — 那時候你資訊不夠。

## 4. 邊界與禁令 (Boundaries)
- 不得跳過 Phase 1。沒 loop 就沒這個 strategy。
- 不得在 Phase 5 寫 regression test 的 seam 是錯的。Test pass 不代表 bug fixed，只代表 test 沒抓到。
- 不得在 fix 之前提出「順便重構」建議。先解決，後思考。
- 不得保留 `[DEBUG-...]` 進 commit。

## 5. 與 CAP agent 的對應
- **10-Troubleshoot**：本 strategy 的主使用者，每次 diagnostic 任務都掛載。
- **07-QA**：在驗證 fix、bug 再現、效能退化分析時掛載；regression test 對應 Phase 5。
- 其他 agent 不主動掛載，但若交接 ticket 內含 bug 診斷子任務，可參考此 strategy。

## 6. 驗收 (Success Criteria)
- 任務結尾能展示：feedback loop 是什麼、怎麼跑、bug 重現了、3-5 ranked hypotheses 是哪幾條、最後對的是哪條、regression test 路徑（或為什麼沒 seam）、`[DEBUG-...]` 已清除。
- 整個診斷的失敗條件：Phase 1 沒做就跳到 fix；fix 沒對應 hypothesis；regression test 在 wrong seam。
