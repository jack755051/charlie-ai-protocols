.PHONY: help setup sync run install uninstall update list check-aliases

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
	@echo "  cap update              # 同步 GitHub 最新規則"
	@echo "  cap run                 # 以預設 nextjs 啟動"
	@echo "  cap run FRAMEWORK=nuxt  # 指定框架啟動"

setup: $(VENV)/bin/activate ## 建立 venv 並安裝依賴（首次執行）
	@echo "✅ 虛擬環境就緒：$(VENV)"

$(VENV)/bin/activate: engine/requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install -r engine/requirements.txt
	@touch $@

sync: ## 重建本地 Agent Skills symlink（不支援時自動 fallback 為 copy）
	@bash scripts/mapper.sh

install: sync ## 全域安裝 Agent 技能至 ~/.agents/skills/、~/.claude/ 並註冊 cap 指令
	@bash scripts/mapper.sh --global
	@bash scripts/manage-cap-alias.sh install "$(CURDIR)"

update: ## 從 GitHub 拉取最新規則並重新安裝
	@git pull --ff-only
	@$(MAKE) install

uninstall: ## 移除全域安裝與 cap 指令
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
