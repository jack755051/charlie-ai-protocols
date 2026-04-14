.PHONY: help setup sync run

VENV     := .venv
PIP      := $(VENV)/bin/pip
PYTHON   := $(VENV)/bin/python
FRAMEWORK ?= nextjs

help: ## 列出所有可用指令
	@echo "Charlie's AI Protocols - 可用指令:"
	@echo ""
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "範例："
	@echo "  make setup              # 首次環境初始化"
	@echo "  make sync               # 更新 Agent 定義後重建 symlink"
	@echo "  make run                # 以預設 nextjs 啟動"
	@echo "  make run FRAMEWORK=nuxt # 指定框架啟動"

setup: $(VENV)/bin/activate ## 建立 venv 並安裝依賴（首次執行）
	@echo "✅ 虛擬環境就緒：$(VENV)"

$(VENV)/bin/activate: engine/requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install -r engine/requirements.txt
	@touch $@

sync: ## 重建 Agent Skills symlink（更新大腦後執行）
	@bash scripts/mapper.sh

run: setup sync ## 初始化策略並啟動 CrewAI 引擎（FRAMEWORK=nextjs|angular|nuxt）
	@bash scripts/init-ai.sh $(FRAMEWORK)
