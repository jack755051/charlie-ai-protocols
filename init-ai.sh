#!/bin/bash

# 從腳本所在位置定位 protocols 目錄，讓 submodule 與本 repo root 兩種執行方式都可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTOCOLS_DIR="$SCRIPT_DIR"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# 通用組裝函數：接收 目標檔名、Edition名稱，以及 不定數量的規則檔案路徑
build_rules() {
    local target_file="$1"
    local edition_name="$2"
    shift 2 # 移除前兩個參數，剩下的 $@ 就是檔案陣列

    # 1. 檢查所有傳入的檔案是否存在
    for file in "$@"; do
        if [ ! -f "$file" ]; then
            echo "❌ 錯誤：找不到規則檔 $(basename "$file")"
            echo "請確認路徑正確：$file"
            exit 1
        fi
    done

    # 2. 寫入起手式
    echo "# Charlie's AI Protocols (${edition_name})" > "$target_file"
    echo "你是一位資深專家與系統架構師，請嚴格遵守以下所有規則與開發邊界：" >> "$target_file"
    echo "" >> "$target_file"

    # 3. 依序合併檔案
    for file in "$@"; do
        cat "$file" >> "$target_file"
        echo "" >> "$target_file" # 加上空行確保排版不會黏在一起
    done
}

print_usage() {
    echo "👉 語法：bash ${SCRIPT_NAME} [type]"
    echo "👉 可用前端：nextjs | angular | nuxt"
    echo "👉 可用管家：git-agent"
    echo "👉 未來擴充：cpp"
}

# ==========================================
# 核心派發邏輯包裝 (Dispatcher Function)
# ==========================================
run_dispatcher() {
    local role_type="$1"

    case "$role_type" in
        "nextjs")
            echo "🤖 正在為 Next.js 專案初始化 AI 規則..."
            build_rules ".cursorrules" "Next.js Edition" \
                "$PROTOCOLS_DIR/01-general-engine.md" \
                "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
                "$PROTOCOLS_DIR/frontend/strategies/nextjs-app-router.md"
            echo "✅ 成功產出 .cursorrules！Next.js 專家已就緒。"
            ;;

        "angular")
            echo "🤖 正在為 Angular 企業級專案初始化 AI 規則..."
            build_rules ".cursorrules" "Angular Edition" \
                "$PROTOCOLS_DIR/01-general-engine.md" \
                "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
                "$PROTOCOLS_DIR/frontend/strategies/angular-enterprise.md"
            echo "✅ 成功產出 .cursorrules！Angular 專家已就緒。"
            ;;

        "nuxt")
            echo "🤖 正在為 Nuxt 專案初始化 AI 規則..."
            build_rules ".cursorrules" "Nuxt Composition Edition" \
                "$PROTOCOLS_DIR/01-general-engine.md" \
                "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
                "$PROTOCOLS_DIR/frontend/strategies/nuxt-composition.md"
            echo "✅ 成功產出 .cursorrules！Nuxt 專家已就緒。"
            ;;

        "git-agent")
            echo "🤖 正在初始化 Git 自動化管家大腦..."
            build_rules ".openclaw-system-prompt" "Git & DevOps Agent Persona" \
                "$PROTOCOLS_DIR/01-general-engine.md" \
                "$PROTOCOLS_DIR/workflow/04-git-workflow-policy.md"
            echo "✅ 成功產出 .openclaw-system-prompt！Git 管家已就緒。"
            ;;

        "cpp")
            echo "⚠️ 敬請期待：C++ 韌體規則尚在建置中。"
            ;;

        *)
            echo "❌ 錯誤：未知的專案/角色類型 '$role_type'"
            print_usage
            exit 1
            ;;
    esac
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
    if [ ! -t 0 ]; then
        echo "❌ 錯誤：目前是非互動式環境，請直接帶入角色類型參數。"
        print_usage
        exit 1
    fi

    # --- 互動式選單模式 ---
    echo "========================================"
    echo "  🤖 Charlie's AI Agent Selector 🤖  "
    echo "========================================"
    echo "請選擇您要喚醒的 AI 助理角色："
    echo "  1) ⚛️  Next.js 前端開發大腦"
    echo "  2) 🛡️  Angular 企業級大腦"
    echo "  3) ⛰️  Nuxt 前端開發大腦"
    echo "  4) 🐙 Git & DevOps 管家大腦"
    echo "  0) ❌ 離開"
    echo "----------------------------------------"
    read -p "請輸入數字 [0-4]: " choice

    case $choice in
        1) run_dispatcher "nextjs" ;;
        2) run_dispatcher "angular" ;;
        3) run_dispatcher "nuxt" ;;
        4) run_dispatcher "git-agent" ;;
        0) echo "👋 取消操作，掰掰！"; exit 0 ;;
        *) echo "❌ 無效的選擇"; exit 1 ;;
    esac
else
    # --- CLI 參數模式 (CI/CD 或快速指令) ---
    run_dispatcher "$1"
fi
