#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - 可用指令:

  cap help                         列出所有可用指令
  cap setup                        建立 venv 並安裝依賴（首次執行）
  cap sync                         重建本地 Agent Skills symlink（不支援時自動 fallback 為 copy）
  cap install                      全域安裝 Agent 技能並註冊 CAP shell wrapper
  cap version                      顯示目前安裝版本、ref 與最新 release tag
  cap update [target]              更新到 latest / main / 指定 tag 或 branch
  cap rollback <tag>               回退到指定 release tag
  cap uninstall                    移除全域安裝與 CAP shell wrapper
  cap list                         列出所有可用的 Agent Skills
  cap check-aliases                驗證本地 Agent alias 映射是否正確
  cap paths                        顯示目前專案的 CAP 本機儲存路徑
  cap registry                     顯示目前 agent registry
  cap promote list                 列出本機可升級的 drafts / reports
  cap promote <src> <dst>          將本機產物升級到 repo 正式路徑
  cap run                          初始化策略並啟動 CrewAI 引擎（FRAMEWORK=nextjs|angular|nuxt）
  cap codex [ARGS...]              透過 wrapper 啟動 Codex，並自動寫入 session trace
  cap claude [ARGS...]             透過 wrapper 啟動 Claude，並自動寫入 session trace
  cap agent <agent> [prompt]       啟動指定 agent 的互動 session，並自動記錄 trace

範例：
  cap setup
  cap sync
  cap install
  cap version
  cap update
  cap update v0.4.0
  cap rollback v0.3.0
  cap registry
  cap promote reports/audit-log.md docs/reports/audit-log.md
  cap codex
  cap claude --agent reviewer
  cap agent frontend "幫我檢查 auth module"
  cap agent qa "幫我補 E2E"

提示：
  若已安裝 shell wrapper，直接輸入 codex / claude 也會經過同一套 trace backend。
EOF
  echo ""
  make -C "${CAP_ROOT}" help >/dev/null
}

COMMAND="${1:-help}"

case "${COMMAND}" in
  help|-h|--help)
    show_help
    ;;
  codex)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" codex "$@"
    ;;
  claude)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" claude "$@"
    ;;
  version|update|rollback)
    exec bash "${SCRIPT_DIR}/cap-release.sh" "$@"
    ;;
  registry)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-registry.sh" show "$@"
    ;;
  promote)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-promote.sh" "$@"
    ;;
  agent)
    shift
    exec bash "${SCRIPT_DIR}/cap-agent.sh" "$@"
    ;;
  *)
    if [ "${COMMAND}" = "paths" ]; then
      shift || true
      exec bash "${SCRIPT_DIR}/cap-paths.sh" show "$@"
    fi
    exec make -C "${CAP_ROOT}" "$@"
    ;;
esac
