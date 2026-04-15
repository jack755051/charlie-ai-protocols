#!/bin/bash
set -euo pipefail

# ==========================================
# Charlie's AI Protocols (CAP) - 一鍵安裝
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/jack755051/charlie-ai-protocols/main/install.sh | bash
# ==========================================

CAP_DIR="${HOME}/.charlie-ai-protocols"
REPO_URL="https://github.com/jack755051/charlie-ai-protocols.git"

echo ""
echo "🧠 Charlie's AI Protocols (CAP) 安裝程式"
echo "=========================================="

# 1. Clone 或更新
if [ -d "${CAP_DIR}/.git" ]; then
  echo "📦 偵測到既有安裝，正在更新..."
  git -C "${CAP_DIR}" pull --ff-only
else
  echo "📥 正在下載 CAP..."
  git clone "${REPO_URL}" "${CAP_DIR}"
fi

# 2. 執行 Makefile 的全域安裝
echo ""
make -C "${CAP_DIR}" install

# 3. 完成提示
echo ""
echo "=========================================="
echo "✅ CAP 安裝完成！"
echo ""
echo "👉 請執行以下指令讓 cap 在當前終端生效："
echo ""
echo "    source ~/.zshrc"
echo ""
echo "或直接開啟新的終端機視窗。之後即可使用："
echo ""
echo "  cap help    — 列出所有可用指令"
echo "  cap list    — 列出 11 個 Agent Skills"
echo "  cap update  — 同步 GitHub 最新規則"
echo "=========================================="
