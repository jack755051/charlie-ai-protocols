.PHONY: help setup sync run install uninstall

VENV     := .venv
PIP      := $(VENV)/bin/pip
PYTHON   := $(VENV)/bin/python
FRAMEWORK ?= nextjs

help: ## 列出所有可用指令
	@echo "Charlie's AI Protocols - 可用指令:"
	@echo ""
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "範例："
	@echo "  make setup              # 首次環境初始化"
	@echo "  make sync               # 更新 Agent 定義後重建本地 symlink"
	@echo "  make install            # 全域安裝（跨 Repo 共用）"
	@echo "  make uninstall          # 移除全域安裝"
	@echo "  make run                # 以預設 nextjs 啟動"
	@echo "  make run FRAMEWORK=nuxt # 指定框架啟動"

setup: $(VENV)/bin/activate ## 建立 venv 並安裝依賴（首次執行）
	@echo "✅ 虛擬環境就緒：$(VENV)"

$(VENV)/bin/activate: engine/requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install -r engine/requirements.txt
	@touch $@

sync: ## 重建本地 Agent Skills symlink（更新大腦後執行）
	@bash scripts/mapper.sh

install: sync ## 全域安裝 Agent 技能至 ~/.agents/skills/ 與 ~/.codex/
	@bash scripts/mapper.sh --global

uninstall: ## 移除全域安裝（不影響本地）
	@bash scripts/mapper.sh --uninstall

run: setup sync ## 初始化策略並啟動 CrewAI 引擎（FRAMEWORK=nextjs|angular|nuxt）
	@bash scripts/init-ai.sh $(FRAMEWORK)
