# Token Monitor — Minimal Fixture for CAP e2e Tests

這份 fixture **不是真實專案**；它是 `tests/e2e/` 下的 deterministic e2e 測試專用最小 CAP 專案骨架。

## 用途

驗證 `scripts/workflows/persist-task-constitution.sh` → `scripts/workflows/emit-handoff-ticket.sh` → `scripts/workflows/fake-sub-agent.sh` 的完整鏈路在沒有 AI runtime 的情況下能跑通。

## 結構

```
tests/e2e/fixtures/token-monitor-minimal/
├── .cap.constitution.yaml   # 含 task_constitution_planning / persistence / handoff_ticket_emit 等 capability 授權
├── .cap.project.yaml        # 對應 project_id = token-monitor-minimal
└── README.md                # 本檔
```

## 測試操作的隔離原則

任何使用本 fixture 的 e2e 測試**必須**：

1. 在 `mktemp -d` 出的 sandbox 中執行（CAP_HOME 指向 sandbox 內目錄）
2. 不寫入真實 `~/.cap/projects/token-monitor/` 或其他 production 路徑
3. 結束時用 `trap 'rm -rf "${SANDBOX}"'` 自動清理

## 為什麼把這份 fixture 放 repo？

讓 e2e 測試可重跑、可審計、跨環境一致。改動本 fixture 視同改 e2e 契約，需走正式 commit + review。
