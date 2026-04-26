#!/bin/bash

set -euo pipefail

# ==========================================
# Charlie's AI Protocols - 初始化與啟動樞紐
# ==========================================

# 1. 路徑定義：從腳本所在位置定位各個目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
PROTOCOLS_DIR="${PROJECT_ROOT}/docs/agent-skills"
ENGINE_DIR="${PROJECT_ROOT}/engine"

# OpenClaw 預設工作區路徑 (可依據您的 OpenClaw 設定調整)
OPENCLAW_WORKSPACE="${HOME}/.openclaw/workspace"

SCRIPT_NAME="$(basename "${BASH_SOURCE}")"

# 2. 幫助與提示說明
print_usage() {
    echo "👉 語法：bash ${SCRIPT_NAME} [type]"
    echo "👉 可用前端策略：nextjs | angular | nuxt"
    echo "👉 範例：bash ${SCRIPT_NAME} nextjs"
}

# 3. 核心派發與執行邏輯 (Dispatcher Function)
run_dispatcher() {
    local role_type="$1"
    local strategy_file=""

    echo "🚀 正在為 [${role_type}] 環境初始化 AI 團隊大腦..."

    # Step A: 判定使用者選擇的技術策略
    case "$role_type" in
        nextjs)  strategy_file="frontend-nextjs.md" ;;
        angular) strategy_file="frontend-angular.md" ;;
        nuxt)    strategy_file="frontend-nuxtjs.md" ;;
        *)
            echo "❌ 錯誤：未知的類型 '${role_type}'"
            print_usage
            exit 1
            ;;
    esac

    # Step B: 準備 OpenClaw 的 PM 大腦 (注入 SOUL.md)
    # 將 Supervisor Agent 的規則掛載為 OpenClaw 的最高指導原則
    if [ -f "${PROTOCOLS_DIR}/01-supervisor-agent.md" ]; then
        mkdir -p "${OPENCLAW_WORKSPACE}"
        cp "${PROTOCOLS_DIR}/01-supervisor-agent.md" "${OPENCLAW_WORKSPACE}/SOUL.md"
        echo "✅ [1/3] 已將總 PM (Supervisor) 規則注入 OpenClaw 工作區: ${OPENCLAW_WORKSPACE}/SOUL.md"
    else
        echo "❌ 警告：找不到 PM 規則檔 (${PROTOCOLS_DIR}/01-supervisor-agent.md)"
    fi

    # Step C: 準備 CrewAI 開發團隊的技術策略 (掛載給 Frontend/Backend 讀取)
    # 這裡將選定的策略檔複製到 engine 下，讓 main.py 知道現在用哪套框架
    if [ -f "${PROTOCOLS_DIR}/strategies/${strategy_file}" ]; then
        cp "${PROTOCOLS_DIR}/strategies/${strategy_file}" "${ENGINE_DIR}/active-strategy.md"
        echo "✅ [2/3] CrewAI 團隊策略已鎖定為: ${strategy_file}"
    else
        echo "❌ 錯誤：找不到技術策略檔 (${PROTOCOLS_DIR}/strategies/${strategy_file})"
        exit 1
    fi

    # Step D: 提供一鍵喚醒團隊的選項 (觸發 CrewAI)
    echo "✅ [3/3] 規則組裝完畢！"
    echo "--------------------------------------------------"
    read -p "🤖 是否要立即喚醒 11 人 AI 開發團隊 (執行 CrewAI 引擎)? (y/n): " confirm
    if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
        echo "🚀 啟動 CrewAI 引擎中..."
        # 進入 engine 資料夾並執行 main.py
        cd "${ENGINE_DIR}" && python main.py
    else
        echo "🛑 已取消啟動。您可以稍後透過指令 'python engine/main.py' 自行喚醒團隊。"
    fi
}

# ==========================================
# 程式進入點 (Entry Point)
# ==========================================

# 判斷是否帶有參數 (-h 或 --help)
if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    print_usage
    exit 0
fi

# 判斷使用者是否完全沒有輸入參數
if [ -z "${1:-}" ]; then
    echo "❌ 錯誤：請帶入您要開發的框架參數。"
    print_usage
    exit 1
else
    # --- CLI 參數模式 ---
    run_dispatcher "$1"
fi