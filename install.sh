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
CAP_VERSION="${CAP_VERSION:-latest}"

echo ""
echo "🧠 Charlie's AI Protocols (CAP) 安裝程式"
echo "=========================================="

CAP_STORAGE_HOME="${CAP_HOME:-${HOME}/.cap}"

agent_count() {
  find "${CAP_DIR}/docs/agent-skills" -maxdepth 1 -type f -name '*-agent.md' | wc -l | tr -d ' '
}

# 1. Clone 或更新
if [ -d "${CAP_DIR}/.git" ]; then
  echo ""
  echo "📦 [1/4] 偵測到既有安裝，正在同步..."
  git -C "${CAP_DIR}" pull --ff-only --quiet
  echo "   ✓ 已同步至最新版本"
else
  echo ""
  echo "📥 [1/4] 正在下載 CAP..."
  git clone --quiet "${REPO_URL}" "${CAP_DIR}"
  echo "   ✓ 已下載至 ${CAP_DIR}"
fi

echo "   ✓ 安裝目標版本：${CAP_VERSION}"
echo ""
echo "🏷 [1.5/4] 對齊版本目標..."
bash "${CAP_DIR}/scripts/cap-release.sh" prepare "${CAP_VERSION}" > /dev/null 2>&1
echo "   ✓ 已切換至 ${CAP_VERSION}"

# 2. 建立 CAP 本機儲存根目錄
echo ""
echo "🗂 [2/4] 建立 CAP 本機儲存區..."
mkdir -p "${CAP_STORAGE_HOME}/projects"
echo "   ✓ 本機儲存根目錄就緒：${CAP_STORAGE_HOME}"

# 3. 建立本地 symlink（不支援時自動 fallback 為 copy）
echo ""
echo "🔗 [3/4] 建立 Agent Skills symlink（不支援時自動 fallback 為 copy）..."
make -C "${CAP_DIR}" sync > /dev/null 2>&1
count="$(agent_count)"
echo "   ✓ 本地 .agents/skills/ 就緒（${count} agents + ${count} aliases）"

# 4. 全域部署（靜默執行）
echo ""
echo "🌐 [4/4] 部署全域設定..."
make -C "${CAP_DIR}" install > /dev/null 2>&1
SHELL_RC="$(bash "${CAP_DIR}/scripts/manage-cap-alias.sh" detect)"
echo "   ✓ Codex  → ~/.codex/AGENTS.md + ~/.agents/skills/"
echo "   ✓ Claude → ~/.claude/CLAUDE.md + ~/.claude/rules/"
echo "   ✓ Agent 入口預設使用 symlink；若環境不支援才改為 copy"
echo "   ✓ Shell  → cap / codex / claude wrapper 已寫入 ${SHELL_RC}"
echo "   ✓ Runtime traces / logs 預設寫入 ${CAP_STORAGE_HOME}/projects/<project_id>/"

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
echo "    cap version 顯示目前安裝版本"
echo "    cap skill list     列出所有 Agent Skills"
echo "    cap workflow list  列出所有 Workflows"
echo "    cap paths   顯示目前專案對應的本機儲存路徑"
echo "    codex       透過 CAP wrapper 啟動 Codex 並自動記錄 trace"
echo "    claude      透過 CAP wrapper 啟動 Claude 並自動記錄 trace"
echo "    cap update  同步 GitHub 最新規則"
echo "=========================================="
