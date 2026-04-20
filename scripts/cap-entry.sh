#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
  make -C "${CAP_ROOT}" help
  echo ""
  echo "CLI wrappers:"
  echo "  cap codex [ARGS...]             透過 wrapper 啟動 Codex，並自動寫入 session trace"
  echo "  cap claude [ARGS...]            透過 wrapper 啟動 Claude，並自動寫入 session trace"
  echo "  cap agent <agent> [prompt]      啟動指定 agent 的互動 session，並自動記錄 trace"
  echo ""
  echo "範例："
  echo "  cap codex"
  echo "  cap claude --agent reviewer"
  echo "  cap agent frontend \"幫我檢查 auth module\""
  echo ""
  echo "提示：若已安裝 shell wrapper，直接輸入 codex / claude 也會經過同一套 trace backend。"
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
  agent)
    shift
    exec bash "${SCRIPT_DIR}/cap-agent.sh" "$@"
    ;;
  *)
    exec make -C "${CAP_ROOT}" "$@"
    ;;
esac
