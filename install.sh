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
DEFAULT_BRANCH="${CAP_DEFAULT_BRANCH:-main}"
SHELL_RC=""
CAP_VERSION="${CAP_VERSION:-latest}"

echo ""
echo "🧠 Charlie's AI Protocols (CAP) installer"
echo "=========================================="

CAP_STORAGE_HOME="${CAP_HOME:-${HOME}/.cap}"

agent_count() {
  find "${CAP_DIR}/agent-skills" -maxdepth 1 -type f -name '*-agent.md' | wc -l | tr -d ' '
}

# Run a sub-command quietly on success, but surface its full output on failure.
# Replaces the previous `> /dev/null 2>&1` pattern which silenced root causes
# and forced users to re-discover the error by hand.
run_silently() {
  local label="$1"
  shift
  local tmp_log
  tmp_log="$(mktemp)"
  local rc=0
  # Use `|| rc=$?` rather than `if cmd; then ...; fi`: in the latter, when cmd
  # fails and there's no else branch, $? on the next line is the if-statement's
  # rc (0, "nothing executed"), not the sub-command's real exit code. The ||
  # form captures the real rc without triggering `set -e`.
  "$@" > "${tmp_log}" 2>&1 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    rm -f "${tmp_log}"
    return 0
  fi
  echo "" >&2
  echo "❌ ${label} failed (exit ${rc}). Captured output:" >&2
  echo "---" >&2
  cat "${tmp_log}" >&2
  echo "---" >&2
  rm -f "${tmp_log}"
  exit "${rc}"
}

# 1. Clone 或更新
if [ -d "${CAP_DIR}/.git" ]; then
  echo ""
  echo "📦 [1/4] Existing install detected, syncing..."
  # cap-release.sh prepare from a prior run can leave HEAD detached at a tag.
  # Re-attach to the default branch before pulling, otherwise `git pull
  # --ff-only` refuses to operate on detached HEAD with a misleading
  # "You are not currently on a branch" error.
  if ! git -C "${CAP_DIR}" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    run_silently "Re-attaching HEAD to ${DEFAULT_BRANCH}" \
      git -C "${CAP_DIR}" checkout --quiet "${DEFAULT_BRANCH}"
  fi
  run_silently "Syncing existing install" \
    git -C "${CAP_DIR}" pull --ff-only --quiet origin "${DEFAULT_BRANCH}"
  echo "   ✓ Synced to the latest revision"
else
  echo ""
  echo "📥 [1/4] Downloading CAP..."
  run_silently "Cloning CAP repository" git clone --quiet "${REPO_URL}" "${CAP_DIR}"
  echo "   ✓ Downloaded to ${CAP_DIR}"
fi

echo "   ✓ Target version: ${CAP_VERSION}"
echo ""
echo "🏷 [1.5/4] Aligning version target..."
run_silently "Aligning version target" \
  bash "${CAP_DIR}/scripts/cap-release.sh" prepare "${CAP_VERSION}"
echo "   ✓ Switched to ${CAP_VERSION}"

# 2. 建立 CAP 本機儲存根目錄
echo ""
echo "🗂 [2/4] Preparing CAP local storage..."
mkdir -p "${CAP_STORAGE_HOME}/projects"
mkdir -p "${CAP_STORAGE_HOME}/designs"
echo "   ✓ Local storage root ready: ${CAP_STORAGE_HOME}"

# 3. 建立本地 symlink（不支援時自動 fallback 為 copy）
echo ""
echo "🔗 [3/4] Creating Agent Skills symlinks (falls back to copy if unsupported)..."
run_silently "Creating Agent Skills symlinks" make -C "${CAP_DIR}" sync
count="$(agent_count)"
echo "   ✓ Local .agents/skills/ ready (${count} agents + ${count} aliases)"

# 4. 全域部署（靜默執行）
echo ""
echo "🌐 [4/4] Deploying global settings..."
run_silently "Deploying global settings" make -C "${CAP_DIR}" install
SHELL_RC="$(bash "${CAP_DIR}/scripts/manage-cap-alias.sh" detect)"
echo "   ✓ Codex  → ~/.agents/skills/"
echo "   ✓ Claude → ~/.claude/rules/"
echo "   ✓ Agent entries default to symlink; falls back to copy if unsupported"
echo "   ✓ Shell  → cap entry written to ${SHELL_RC} (bare claude / codex stay on native provider)"
echo "   ✓ Runtime traces / logs are written to ${CAP_STORAGE_HOME}/projects/<project_id>/ by default"

# 4. 完成提示
echo ""
echo "=========================================="
echo "✅ CAP install complete!"
echo ""
echo "👉 Run the following to activate cap in the current shell:"
echo ""
echo "    source ${SHELL_RC}"
echo ""
echo "Or open a new terminal window. Then you can use:"
echo ""
echo "    cap help           Show all available commands"
echo "    cap version        Show the installed version"
echo "    cap skill list     List all Agent Skills"
echo "    cap workflow list  List all Workflows"
echo "    cap paths          Show local storage paths for the current project"
echo "    cap codex          Launch Codex via the CAP wrapper with trace logging"
echo "    cap claude         Launch Claude via the CAP wrapper with trace logging"
echo "    cap update         Sync the latest rules from GitHub"
echo ""
echo "ℹ Provider isolation: bare claude / codex keep native provider behaviour (not routed through CAP)."
echo "  For CAP-managed sessions use cap claude / cap codex. To restore the legacy behaviour where"
echo "  CAP wraps the bare CLIs and records traces, run: CAP_WRAP_NATIVE_CLI=1 make install."
echo "=========================================="
