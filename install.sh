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
SHELL_RC=""

echo ""
echo "🧠 Charlie's AI Protocols (CAP) 安裝程式"
echo "=========================================="

agent_count() {
  find "${CAP_DIR}/docs/agent-skills" -maxdepth 1 -type f -name '*-agent.md' | wc -l | tr -d ' '
}

# 1. Clone 或更新
if [ -d "${CAP_DIR}/.git" ]; then
  echo ""
  echo "📦 [1/3] 偵測到既有安裝，正在同步..."
  git -C "${CAP_DIR}" pull --ff-only --quiet
  echo "   ✓ 已同步至最新版本"
else
  echo ""
  echo "📥 [1/3] 正在下載 CAP..."
  git clone --quiet "${REPO_URL}" "${CAP_DIR}"
  echo "   ✓ 已下載至 ${CAP_DIR}"
fi

# 2. 建立本地 symlink（不支援時自動 fallback 為 copy）
echo ""
echo "🔗 [2/3] 建立 Agent Skills symlink（不支援時自動 fallback 為 copy）..."
make -C "${CAP_DIR}" sync > /dev/null 2>&1
count="$(agent_count)"
echo "   ✓ 本地 .agents/skills/ 就緒（${count} agents + ${count} aliases）"

# 3. 全域部署（靜默執行）
echo ""
echo "🌐 [3/3] 部署全域設定..."
make -C "${CAP_DIR}" install > /dev/null 2>&1
SHELL_RC="$(bash "${CAP_DIR}/scripts/manage-cap-alias.sh" detect)"
echo "   ✓ Codex  → ~/.codex/AGENTS.md + ~/.agents/skills/"
echo "   ✓ Claude → ~/.claude/CLAUDE.md + ~/.claude/rules/"
echo "   ✓ Agent 入口預設使用 symlink；若環境不支援才改為 copy"
echo "   ✓ Shell  → cap / codex / claude wrapper 已寫入 ${SHELL_RC}"

# 4. 完成提示
echo ""
echo "=========================================="
echo "✅ CAP 安裝完成！"
echo ""
echo "👉 請執行以下指令讓 cap 在當前終端生效："
echo ""
echo "    source ${SHELL_RC}"
echo ""
echo "或直接開啟新的終端機視窗。之後即可使用："
echo ""
echo "    cap help    列出所有可用指令"
echo "    cap list    列出所有 Agent Skills"
echo "    codex       透過 CAP wrapper 啟動 Codex 並自動記錄 trace"
echo "    claude      透過 CAP wrapper 啟動 Claude 並自動記錄 trace"
echo "    cap update  同步 GitHub 最新規則"
echo "=========================================="
