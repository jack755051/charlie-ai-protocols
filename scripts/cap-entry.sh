#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - Start Here

COMMAND                            DESCRIPTION
─────────────────────────────────  ──────────────────────────────────────────────

[Start]
  cap help                         列出常用指令
  cap help --advanced              列出維護、診斷與 legacy 指令
  cap version                      顯示版本、ref 與最新 release tag
  cap update [target]              更新到 latest / main / 指定 tag 或 branch

[Discover]
  cap skill list                   列出所有 Agent Skills
  cap workflow list                列出所有 workflow（靜態清單）

[Repo Setup]
  cap project init [--project-id ID] [--force]   將目前 repo 接入 CAP，建立 project_id / storage / ledger
  cap project status [--format text|json|yaml]  顯示目前 repo 的 CAP 身份與 storage 狀態
  cap project doctor [--format text|json|yaml]  檢查 CAP project 設定與 storage 健康狀態

[Run Workflows]
  cap workflow run <id> [prompt]   在已接入 CAP 的 repo 內執行 workflow（預設 CLI: claude）
  cap workflow run --dry-run <id> [prompt]  預覽 workflow 執行計畫，不呼叫 AI

[Provider]
  cap provider doctor [--json]     檢查 claude / codex CLI 是否可用（read-only，不代登入）

[Shortcuts]
  cap p init/status/doctor         shorthand for cap project init/status/doctor
  cap proj ...                     shorthand for cap project ...
  cap wf ...                       shorthand for cap workflow ...
  cap prov doctor                  shorthand for cap provider doctor

更多維護、診斷與 legacy 指令：
  cap help --advanced
EOF
}

show_advanced_help() {
  cat <<'EOF'
Charlie's AI Protocols (CAP) - Advanced / Maintenance

COMMAND                            DESCRIPTION
─────────────────────────────────  ──────────────────────────────────────────────

[Setup & Install]
  cap setup                        建立 venv 並安裝依賴（通常由 installer 處理）
  cap sync                         重建本地 Agent Skills symlink
  cap install                      全域安裝 Agent 技能並註冊 shell wrapper
  cap uninstall                    移除全域安裝與 shell wrapper
  cap release-check [--all|--recent N]  檢查 release metadata 是否低訊號
  cap paths                        顯示 CAP 本機儲存路徑（診斷用）

[Skill & Registry]
  cap skill registry               顯示 agent registry
  cap skill check-aliases          驗證 alias 映射是否正確

[Project]
  cap project constitution (--prompt "<需求>" | --from-file PATH | --promote STAMP | --latest)
                                                   產出 / 匯入 / 將 Project Constitution snapshot 寫回 repo SSOT

[Task / Compiler]
  cap task constitution "<需求>"     從一句話需求產出 Task Constitution
  cap task plan "<需求>"             (planned) task constitution + capability graph 預覽
  cap task compile "<需求>"          (planned) task constitution + graph + compiled workflow + binding bundle
  cap task run "<需求>"              (planned) compile + execute via runtime binder
  cap workflow constitution "<需求>"   [DEPRECATED] 產出 task constitution — 改用 cap task constitution
  cap workflow compile "<需求>"        從一句話需求編譯最小 workflow
  cap workflow run-task "<需求>"       從一句話需求直接 compile 並執行
  cap workflow <id> "<prompt>"        run 的簡寫

[Workflow Runtime]
  cap workflow ps                  列出正在執行的 workflow run
  cap workflow ps --all            列出所有歷史 workflow run
  cap workflow run --strategy auto <id> [prompt]  自動選擇 fast / governed / strict strategy
  cap workflow run --cli codex <id> [prompt]      指定使用 codex 執行
  cap workflow run --design-package <name> <id> [prompt]  使用 ~/.cap/designs/<name> 設計稿 package
  cap workflow show <id>           顯示 workflow 摘要
  cap workflow plan <id>           顯示 semantic plan、phase 與 binding 摘要
  cap workflow bind <id> [registry]  顯示 skill binding report
  cap workflow inspect <run-id>    顯示單次 workflow run 詳情

[Execution]
  cap codex [ARGS...]              CAP project 內記錄 trace；非 CAP 目錄退回原生 Codex
  cap claude [ARGS...]             CAP project 內記錄 trace；非 CAP 目錄退回原生 Claude
  cap session inspect <session_id> [--json]  查 agent session ledger（read-only）
  cap session analyze [--top N] [--json]    彙整 token / time 熱點分析（read-only）

[Promote]
  cap promote inspect <id>         檢查可 promote 的 runtime artifact
  cap promote project-constitution <task_id>  將 Project Constitution 寫回 repo SSOT
  cap promote workflow <workflow_id>          將 workflow artifact 寫回 repo SSOT

[Replay]
  cap replay verify <run_id>       比對舊 run 的 builtin agent-skills baseline 是否仍可重放

[Supervisor Orchestration]
  cap workflow bind supervisor-orchestration       envelope schema + drift gate
  -> runtime dispatcher（halt / retry / route_back / escalate）尚未接通，詳見 docs/cap/ARCHITECTURE.md

[Legacy / Debug]
  cap run                          啟動 CrewAI 引擎 (FRAMEWORK=nextjs|angular|nuxt)
  cap agent <agent> [prompt]       啟動指定 agent 互動 session
  cap artifact list / inspect / by-step      查 runtime-state.json artifact registry
  cap promote list                 列出可升級的 drafts / reports（legacy generic mode）
  cap promote <src> <dst>          將本機產物升級到 repo 正式路徑（legacy generic mode）
EOF
}

unknown_command() {
  local command="$1"
  echo "未知的 cap 指令: ${command}" >&2
  echo "請執行 'cap help' 查看可用指令。" >&2
  exit 1
}

COMMAND="${1:-help}"

case "${COMMAND}" in
  help|-h|--help)
    shift || true
    case "${1:-}" in
      ""|-h|--help)
        show_help
        ;;
      --advanced|advanced)
        show_advanced_help
        ;;
      *)
        echo "未知的 help 選項: $1" >&2
        echo "可用: cap help | cap help --advanced" >&2
        exit 1
        ;;
    esac
    ;;
  codex)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" codex "$@"
    ;;
  claude)
    shift
    exec bash "${SCRIPT_DIR}/cap-session.sh" claude "$@"
    ;;
  session)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-session.sh" "$@"
    ;;
  artifact)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-artifact.sh" "$@"
    ;;
  version|update|rollback|release-check)
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
  check-aliases|registry)
    exec "$0" skill "${COMMAND}" "$@"
    ;;
  workflow|wf)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-workflow.sh" "$@"
    ;;
  project|p|proj)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-project.sh" "$@"
    ;;
  task)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-task.sh" "$@"
    ;;
  promote)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-promote.sh" "$@"
    ;;
  replay)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-replay.sh" "$@"
    ;;
  agent)
    shift
    exec bash "${SCRIPT_DIR}/cap-agent.sh" "$@"
    ;;
  provider|prov)
    shift || true
    exec bash "${SCRIPT_DIR}/cap-provider.sh" "$@"
    ;;
  *)
    if [ "${COMMAND}" = "paths" ]; then
      shift || true
      exec bash "${SCRIPT_DIR}/cap-paths.sh" show "$@"
    fi
    unknown_command "${COMMAND}"
    ;;
esac
