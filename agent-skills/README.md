# Agent Skills Registry

> Status: 已重新分層 — skills 屬於 provider 可讀取的 prompt / policy 素材，
> 不是 CAP 自動派工的 agent army。
>
> 政策依據：
> - [`docs/cap/CAP-POSITIONING.md`](../docs/cap/CAP-POSITIONING.md)
> - [`docs/cap/CAP-LEAN-ROADMAP.md`](../docs/cap/CAP-LEAN-ROADMAP.md) §P2 Skill Model Reclassification

## Skills 是什麼 / 不是什麼

```text
Skills are prompt / policy material that providers may read.
They are not automatically launched as a CAP default team.
```

- **是**：當 Claude Code / Codex 等 provider 在 repo 內做實作或審查時，
  可以被當作 system prompt / role context 載入的 markdown 規範。
- **是**：CAP 在 `skill-registry` 解析時可以把某個 capability 綁定到對應檔，
  讓 workflow step 在執行前自動把該檔的內容當 prompt context 注入。
- **不是**：CAP 預設啟動的 agent army。CAP 平台層的責任是 governance + readiness
  + observability，不是負責「依流水線順序自動把這些角色叫齊」。
- **不是**：舊版 README 描述的「流水線協作 / 系統大腦中樞」雙軌架構。該敘事已隨
  AI-heavy workflow 一併降權至 legacy，見
  [`docs/cap/CAP-LEAN-ROADMAP.md`](../docs/cap/CAP-LEAN-ROADMAP.md) §Workflow Surface。

## 使用分層 (Usage Tiers)

依「與 CAP lean core（governance + readiness + observability）對齊程度」分三層。
編號與檔名穩定不變；分層只是描述 provider 載入時的優先序與 CAP 對該檔的態度。

### Tier 1 — Core Governance

對齊 CAP 平台層的治理、稽核、可追溯性。Provider 在做 repo work 時若觸發
與品質門禁 / 安全 / 排查 / 治理 / 紀錄相關的 capability，會由 CAP 的 skill
registry 把這些檔接上來。

| 檔案 | 角色定位 |
|---|---|
| [`00-core-protocol.md`](00-core-protocol.md) | 👑 全域憲法。每個 agent skill 載入時的共同 preamble，不算 agent 但屬此層管轄。 |
| [`01-supervisor-agent.md`](01-supervisor-agent.md) | 🧠 Supervisor — 任務拆解與派工策略；指導 provider 在收到使用者請求時如何結構化整體工作。 |
| [`06-devops-agent.md`](06-devops-agent.md) | 🛠️ DevOps — CI/CD、容器化、版本控制 commit 策略。 |
| [`07-qa-agent.md`](07-qa-agent.md) | 🧪 QA — 功能驗證、E2E、壓測、Lighthouse 等品質策略。 |
| [`08-security-agent.md`](08-security-agent.md) | 🛡️ Security — 安全稽核、OWASP 防禦、機敏資訊處理。 |
| [`10-troubleshoot-agent.md`](10-troubleshoot-agent.md) | 🔧 Troubleshoot — 故障根因分析與修復建議。 |
| [`90-watcher-agent.md`](90-watcher-agent.md) | 🔍 Watcher — 橫向稽核軌，依 workflow `governance.watcher_mode` 介入。 |
| [`99-logger-agent.md`](99-logger-agent.md) | 📝 Logger — 可追溯性監管軌，依 workflow `governance.logger_mode` 介入。 |
| [`101-readme-agent.md`](101-readme-agent.md) | 📘 README — Repo Intake、README 規範化、機器可解析入口治理。 |

### Tier 2 — Advisory Execution

Provider 在實作時可參考的領域建議。**不是** CAP 自動執行的角色 — 載入與否
由 provider 依任務內容與 repo capability 綁定決定。

| 檔案 | 角色定位 |
|---|---|
| [`02-techlead-agent.md`](02-techlead-agent.md) | 🧭 Tech Lead — 技術評估、架構細化、可行性判斷。 |
| [`02a-ba-agent.md`](02a-ba-agent.md) | 📋 BA — 業務流程可視化、Bounded Context、語意邊界。 |
| [`02b-dba-api-agent.md`](02b-dba-api-agent.md) | 📐 DBA / API — Schema SSOT、API 介面合約、聚合根守門。 |
| [`03-ui-agent.md`](03-ui-agent.md) | 🎨 UI / UX — 設計系統、設計資產、Tokens / Screens / Prototype。 |
| [`04-frontend-agent.md`](04-frontend-agent.md) | 💻 Frontend — Angular / Next / Nuxt 共通架構與資料邊界。 |
| [`05-backend-agent.md`](05-backend-agent.md) | ⚙️ Backend — .NET / NestJS Clean Architecture、Aggregate / VO / Domain Event。 |
| [`11-sre-agent.md`](11-sre-agent.md) | 📊 SRE — 效能瓶頸診斷、可靠性方案、快取與資源優化。 |

### Tier 3 — Deferred / Optional

整合擴張面 — 與外部設計工具、產品分析、外來工程哲學 / 框架特化策略相關。
目前不在 CAP lean core；保留供 provider 在明確需要時主動引用。

| 檔案 | 角色定位 |
|---|---|
| [`09-analytics-agent.md`](09-analytics-agent.md) | 📈 Analytics — KPI、漏斗、A/B Test、埋點規格。 |
| [`12-figma-agent.md`](12-figma-agent.md) | 🖼️ Figma Sync — 將第一層設計資產同步到 Figma（MCP / 匯入腳本）。 |
| [`strategies/karpathy-guidelines.md`](strategies/karpathy-guidelines.md) | 🧪 Karpathy Guidelines — 外來工程哲學參考，非 CAP 自家規範。 |
| [`strategies/`](strategies/) (其餘) | 框架特化策略：Angular / Next / Nuxt / NestJS / .NET / Playwright / k6 / Lighthouse / TDD vertical slice / architecture-deepening / diagnose-loop / shared-language-and-adr / vertical-slice-planning / unit-test-{frontend,backend}。Provider 可在實作該框架時掛載。 |

## CAP 如何使用這些檔（簡述）

1. **Capability 綁定**：`schemas/capabilities.yaml` 內的 capability 透過
   `default_agent` / `allowed_agents` 指向某個 role key。
2. **Skill registry 解析**：`RuntimeBinder` 透過 project / shared / builtin 三層
   `skills.yaml` 把 role 解析到具體 skill 檔。
3. **執行階段載入**：當 workflow step 進入時，runtime 把該檔的內容當作
   prompt context 餵給 provider；provider 在該 step 結束後不會「常駐」這個角色。
4. **無自動派工**：CAP **不會**主動依檔名編號跑出一條「PRD → TechPlan → BA → DBA → ...」
   的流水線。這種流水線屬於 legacy workflow（`project-spec-pipeline` /
   `project-implementation-pipeline` / `project-qa-pipeline` /
   `supervisor-orchestration`），均已標 legacy，見
   [`schemas/workflows/`](../schemas/workflows/) 對應 YAML 頂端的 Status header。

## 對舊敘事的處置

舊版 README（v3.x 之前）有一張「流水線流程」圖把 17 個 agent 描述成
從 PM → DevOps → Logger 的單向自動鏈，並用「系統大腦中樞」稱呼整個目錄。
該敘事在 CAP lean 重構後已被廢止，原因：

- CAP 平台層的核心不是「主導多 agent 自動執行」，而是
  「在 provider 做 AI 工作前後做 governance + observability」。
- 多 agent 自動鏈所需的 workflow（`project-spec-pipeline` 等）皆已標 legacy。
- Provider（Claude Code / Codex 等）才是真正執行的主體；skills 是它們可讀的
  外部資料，不是 CAP 跑出來的內部 agent。

歷史敘事可在 git history 與
[`development-records/closeouts/cap-dogfood-convergence-2026-05-15.md`](../development-records/closeouts/cap-dogfood-convergence-2026-05-15.md)
回讀。
