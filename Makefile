.PHONY: help setup sync run install uninstall update version rollback list check-aliases workflow

VENV      := .venv
PIP       := $(VENV)/bin/pip
PYTHON    := $(VENV)/bin/python
FRAMEWORK ?= nextjs

help: ## 列出所有可用指令
	@echo "Charlie's AI Protocols (CAP) - 可用指令:"
	@echo ""
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  cap %-15s %s\n", $$1, $$2}'
	@echo ""
	@echo "範例："
	@echo "  cap setup               # 首次環境初始化"
	@echo "  cap sync                # 更新 Agent 定義後重建本地 symlink（不支援時自動 fallback 為 copy）"
	@echo "  cap install             # 全域安裝（跨 Repo 共用）"
	@echo "  cap uninstall           # 移除全域安裝"
	@echo "  cap version             # 顯示目前安裝版本與最新 release tag"
	@echo "  cap update              # 更新到最新 release tag"
	@echo "  cap update main         # 切到 main 並同步最新 HEAD"
	@echo "  cap rollback v0.3.0     # 回退到指定 release tag"
	@echo "  cap paths               # 顯示目前專案對應的本機儲存路徑"
	@echo "  cap registry            # 顯示 agent registry"
	@echo "  cap workflow list       # 列出所有 workflow"
	@echo "  cap workflow ps         # 列出 workflow run instance 狀態"
	@echo "  cap workflow show <id>  # 顯示 workflow 摘要"
	@echo "  cap workflow inspect <run-id> # 顯示單次 workflow run 詳情"
	@echo "  cap workflow plan <id>  # 顯示 workflow phase 與 agent 綁定"
	@echo "  cap workflow run <id>   # 前景執行；無 prompt 時會先詢問或只顯示 plan"
	@echo "  cap workflow run --dry-run <id>  # 只顯示執行計畫，不真的執行"
	@echo "  cap promote list        # 列出本機 drafts / reports"
	@echo "  cap run                 # 以預設 nextjs 啟動"
	@echo "  cap run FRAMEWORK=nuxt  # 指定框架啟動"
	@echo ""
	@echo "Wrapper 範例："
	@echo "  cap codex               # 透過 wrapper 啟動 Codex 並自動記錄 session trace"
	@echo "  cap claude              # 透過 wrapper 啟動 Claude 並自動記錄 session trace"
	@echo "  cap agent frontend \"幫我檢查 auth module\""
	@echo "  cap workflow list"
	@echo "  cap workflow ps"
	@echo "  cap workflow show version-control-private"
	@echo "  cap workflow inspect <run-id>"
	@echo "  cap workflow plan version-control-private"
	@echo "  cap workflow run --dry-run version-control-private"
	@echo "  cap workflow run version-control-private \"請針對目前變更建立 commit\""

setup: $(VENV)/bin/activate ## 建立 venv 並安裝依賴（首次執行）
	@echo "✅ 虛擬環境就緒：$(VENV)"

$(VENV)/bin/activate: engine/requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install -r engine/requirements.txt
	@touch $@

sync: ## 重建本地 Agent Skills symlink（不支援時自動 fallback 為 copy）
	@bash scripts/mapper.sh

install: sync ## 全域安裝 Agent 技能並註冊 cap / codex / claude shell wrapper
	@bash scripts/mapper.sh --global
	@bash scripts/manage-cap-alias.sh install "$(CURDIR)"

version: ## 顯示目前安裝版本與最新 release tag
	@bash scripts/cap-release.sh version

update: ## 更新到最新 release tag；可用 cap update <target>
	@bash scripts/cap-release.sh update latest

rollback: ## 回退到指定 release tag；請改用 cap rollback <tag>
	@echo "請使用：cap rollback <tag>"
	@exit 1

uninstall: ## 移除全域安裝與 CAP shell wrapper
	@bash scripts/mapper.sh --uninstall
	@bash scripts/manage-cap-alias.sh uninstall

list: ## 列出所有可用的 Agent Skills
	@echo "Agent Skills (docs/agent-skills/):"
	@echo ""
	@printf "  %-6s %-26s %-14s %s\n" "編號" "檔案" "\$$前綴" "角色"
	@echo "  ------------------------------------------------------------------"
	@for f in docs/agent-skills/*-agent.md; do \
		name=$$(basename "$$f"); \
		num=$$(echo "$$name" | sed 's/-.*//' ); \
		case "$$name" in \
			02a-ba-agent.md) alias_name="ba" ;; \
			02b-dba-api-agent.md) alias_name="dba" ;; \
			*) alias_name=$$(echo "$$name" | sed -E 's/^[0-9]+[a-z]*-//; s/-agent\.md$$//') ;; \
		esac; \
		title=$$(head -1 "$$f" | sed 's/^# *//'); \
		printf "  %-6s %-26s \$$%-13s %s\n" "$$num" "$$name" "$$alias_name" "$$title"; \
	done
	@echo ""
	@echo "共 $$(ls docs/agent-skills/*-agent.md | wc -l | tr -d ' ') 個 Agent"

check-aliases: sync ## 驗證本地 Agent alias 映射是否正確
	@bash scripts/check-aliases.sh

run: setup sync ## 初始化策略並啟動 CrewAI 引擎（FRAMEWORK=nextjs|angular|nuxt）
	@bash scripts/init-ai.sh $(FRAMEWORK)

workflow: ## 顯示 workflow 子指令用法（請改用 cap workflow <subcommand>）
	@echo "請使用："
	@echo "  cap workflow list"
	@echo "  cap workflow ps"
	@echo "  cap workflow show <workflow_id>"
	@echo "  cap workflow inspect <run_id>"
	@echo "  cap workflow plan <workflow_id>"
	@echo "  cap workflow run --dry-run <workflow_id> [prompt]"
	@echo "  cap workflow run <workflow_id> [prompt]"
