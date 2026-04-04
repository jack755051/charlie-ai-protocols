#!/bin/bash

# 從腳本所在位置定位 protocols 目錄，讓 submodule 與本 repo root 兩種執行方式都可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTOCOLS_DIR="$SCRIPT_DIR"

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

# ==========================================
# 角色派發邏輯 (Role Dispatcher)
# ==========================================

if [ "$1" == "nextjs" ]; then
    echo "🤖 正在為 Next.js 專案初始化 AI 規則..."
    build_rules ".cursorrules" "Next.js Edition" \
        "$PROTOCOLS_DIR/01-general-engine.md" \
        "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
        "$PROTOCOLS_DIR/frontend/strategies/nextjs-app-router.md"
    echo "✅ 成功產出 .cursorrules！前端專家已就緒。"

elif [ "$1" == "angular" ]; then
    echo "🤖 正在為 Angular 企業級專案初始化 AI 規則..."
    build_rules ".cursorrules" "Angular Edition" \
        "$PROTOCOLS_DIR/01-general-engine.md" \
        "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
        "$PROTOCOLS_DIR/frontend/strategies/angular-enterprise.md"
    echo "✅ 成功產出 .cursorrules！Angular 專家已就緒。"

elif [ "$1" == "nuxt" ]; then
    echo "🤖 正在為 Nuxt 專案初始化 AI 規則..."
    build_rules ".cursorrules" "Nuxt Composition Edition" \
        "$PROTOCOLS_DIR/01-general-engine.md" \
        "$PROTOCOLS_DIR/frontend/02-frontend-standard.md" \
        "$PROTOCOLS_DIR/frontend/strategies/nuxt-composition.md"
    echo "✅ 成功產出 .cursorrules！Nuxt 專家已就緒。"

elif [ "$1" == "git-agent" ]; then
    echo "🤖 正在初始化 Git 自動化管家大腦..."
    # 假設 OpenClaw 或其他 CLI Agent 讀取的是特定的 prompt 檔
    build_rules ".openclaw-system-prompt" "Git & DevOps Agent Persona" \
        "$PROTOCOLS_DIR/01-general-engine.md" \
        "$PROTOCOLS_DIR/workflow/04-git-workflow-policy.md"
    echo "✅ 成功產出 .openclaw-system-prompt！Git 管家已就緒。"

elif [ "$1" == "cpp" ]; then
    echo "🤖 正在為 C++ 韌體專案初始化 AI 規則..."
    # 未來建立硬體目錄後，解除註解即可使用
    # build_rules ".cursorrules" "C++ Firmware Edition" \
    #     "$PROTOCOLS_DIR/01-general-engine.md" \
    #     "$PROTOCOLS_DIR/hardware/02-embedded-standard.md"
    echo "⚠️ 敬請期待：C++ 韌體規則尚在建置中。"

else
    echo "❌ 錯誤：請提供專案/角色類型。"
    echo "👉 語法：bash docs/skills/init-ai.sh [type]"
    echo "👉 可用類型：nextjs | angular | nuxt | git-agent | cpp"
fi
