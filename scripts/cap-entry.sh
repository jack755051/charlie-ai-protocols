#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - 可用指令

COMMAND                            DESCRIPTION
─────────────────────────────────  ──────────────────────────────────────────────

[Setup & Install]
  cap help                         列出所有可用指令
  cap setup                        建立 venv 並安裝依賴（首次執行）
  cap sync                         重建本地 Agent Skills symlink
  cap install                      全域安裝 Agent 技能並註冊 shell wrapper
  cap uninstall                    移除全域安裝與 shell wrapper
  cap version                      顯示版本、ref 與最新 release tag
  cap update [target]              更新到 latest / main / 指定 tag 或 branch

[Skill & Registry]
  cap skill list                   列出所有 Agent Skills
  cap skill registry               顯示 agent registry
  cap skill check-aliases          驗證 alias 映射是否正確
  cap paths                        顯示 CAP 本機儲存路徑

[Workflow]
  cap workflow list                列出所有 workflow（靜態清單）
  cap workflow ps                  列出正在執行的 workflow run
  cap workflow ps --all            列出所有歷史 workflow run
  cap workflow show <id>           顯示 workflow 摘要
  cap workflow inspect <run-id>    顯示單次 workflow run 詳情
  cap workflow plan <id>           顯示 semantic plan、phase 與 binding 摘要
  cap workflow bind <id> [registry]  顯示 skill binding report
  cap workflow constitution "<需求>"   產出 task constitution
  cap workflow compile "<需求>"        從一句話需求編譯最小 workflow
  cap workflow run-task "<需求>"       從一句話需求直接 compile 並執行
  cap workflow run <id> [prompt]   前景執行（預設 CLI: claude）
  cap workflow run --cli codex <id> [prompt]  指定使用 codex 執行
  cap workflow run --dry-run <id> [prompt]  只顯示執行計畫，不真的執行
  cap workflow <id> "<prompt>"     run 的簡寫

[Execution]
  cap run                          啟動 CrewAI 引擎 (FRAMEWORK=nextjs|angular|nuxt)
  cap agent <agent> [prompt]       啟動指定 agent 互動 session
  cap codex [ARGS...]              透過 wrapper 啟動 Codex（含 trace）
  cap claude [ARGS...]             透過 wrapper 啟動 Claude（含 trace）

[Artifacts]
  cap promote list                 列出可升級的 drafts / reports
  cap promote <src> <dst>          將本機產物升級到 repo 正式路徑
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
  skill)
    shift || true
    SUB="${1:-list}"
    case "${SUB}" in
      list)
        shift || true
        exec make -C "${CAP_ROOT}" skill-list "$@"
        ;;
      registry)
        shift || true
        exec bash "${SCRIPT_DIR}/cap-registry.sh" show "$@"
        ;;
      check-aliases)
        shift || true
        exec make -C "${CAP_ROOT}" check-aliases "$@"
        ;;
      *)
        echo "未知的 skill 子指令: ${SUB}" >&2
        echo "可用指令: cap skill list | registry | check-aliases" >&2
        exit 1
        ;;
    esac
    ;;
  list)
    echo "cap list 已移除。請改用：" >&2
    echo "  cap skill list       # 列出 Agent Skills" >&2
    echo "  cap workflow list     # 列出 Workflows" >&2
    exit 1
    ;;
  check-aliases|registry)
    exec "$0" skill "${COMMAND}" "$@"
    ;;
  workflow)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-workflow.sh" "$@"
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
